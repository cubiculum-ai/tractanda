import XCTest

@testable import TractandaCore

final class CoreTests: XCTestCase {
    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tractanda-\(Identifier.make())")
    }
    private func files(_ root: URL) -> [URL] {
        (FileManager.default.enumerator(
            at: root.appendingPathComponent("items"), includingPropertiesForKeys: nil)?.allObjects as? [URL]
            ?? []).filter { $0.pathExtension == "tractanda" }
    }
    private func edit(
        _ store: ItemStore, _ base: Revision, _ fields: [String: ItemValue], unset: [String] = []
    ) throws -> Revision {
        try store.commit(
            CommitRequest(
                action: .revise, itemID: base.itemID, expectedRevisionID: base.revisionID,
                changes: fields, unset: unset, operationID: Identifier.make())
        ).revision
    }
    private func assertCode(
        _ code: String, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual((error as? TractandaError)?.code, code, "\(error)", file: file, line: line)
        }
    }
    func testInitialStoreAndFixture() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tractanda-\(Identifier.make())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        let fixture = try DemoFixture.seed(store)
        XCTAssertEqual(fixture.count, 8)
        XCTAssertEqual(try store.candidates().count, 8)
    }

    func testGenericItemIsConcreteAndRootAncestryDoesNotRepeat() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        let item = try store.commit(
            CommitRequest(
                classID: "Item", changes: ["subject": .text("Generic content")],
                operationID: "create-root-item")
        ).revision
        XCTAssertTrue(type(of: ItemTypes.makeItem(from: item)) == Item.self)
        XCTAssertEqual(ItemTypes.ancestry(item.classID), ["Item"])
        XCTAssertNil(ItemTypes.parents["Item"])
        XCTAssertFalse(ItemTypes.abstract.contains("Item"))
        XCTAssertTrue(try SpotlightQuery("classID == \"Item\"").matches(item))
        XCTAssertTrue(try SpotlightQuery("kMDItemContentTypeTree == \"Item\"").matches(item))
        let person = try store.commit(
            CommitRequest(
                classID: "NaturalPersonItem", changes: ["subject": .text("Someone")],
                operationID: "create-person")
        ).revision
        XCTAssertEqual(ItemTypes.ancestry(person.classID), ["NaturalPersonItem", "PersonItem", "Item"])
        XCTAssertFalse(try SpotlightQuery("classID == \"Item\"").matches(person))
        XCTAssertTrue(try SpotlightQuery("kMDItemContentTypeTree == \"Item\"").matches(person))
        for classID in ItemTypes.abstract {
            assertCode("abstractClass") {
                _ = try store.commit(
                    CommitRequest(classID: classID, changes: [:], operationID: "abstract-\(classID)"))
            }
        }
    }

    func testRetiredPrototypeCapabilityCannotSubmitWrites() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        let service = ItemService(store: store)
        let data = try JSONSerialization.data(withJSONObject: [
            "using": ["https://tractanda.ai/ns/local-prototype/2"],
            "methodCalls": [
                [
                    "TractandaItem/commit",
                    [
                        "action": "create", "classID": "NoteItem", "changes": [:],
                        "unset": [], "operationID": "stale-client-create",
                    ], "old-client",
                ]
            ],
        ])
        let response =
            try JSONSerialization.jsonObject(
                with: service.handle(data, peerUID: store.ownerUID)) as! [String: Any]
        XCTAssertEqual(response["code"] as? String, "invalidRequest")
        XCTAssertTrue((response["message"] as? String)?.contains(ItemService.capability) == true)
        XCTAssertTrue(try store.candidates().isEmpty)
    }

    func testRevisionIdentityWholeEditsRetryAndRecovery() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        var store: ItemStore? = try ItemStore(root: root)
        let first = try store!.commit(
            CommitRequest(
                classID: "Item", changes: ["subject": .text("First")], operationID: "create-note")
        ).revision
        let path = files(root)[0]
        let original = try Data(contentsOf: path)
        let request = CommitRequest(
            action: .revise, itemID: first.itemID, expectedRevisionID: first.revisionID,
            changes: ["subject": .text("Second"), "body": .text("Two fields, one edit")],
            operationID: "edit-note")
        let second = try store!.commit(request).revision
        XCTAssertEqual(second.itemID, first.itemID)
        XCTAssertNotEqual(second.revisionID, first.revisionID)
        XCTAssertEqual(try store!.history(first.itemID).count, 2)
        XCTAssertEqual(try Data(contentsOf: path), original)
        XCTAssertTrue(try store!.commit(request).wasReplayed)
        var conflict = request
        conflict.operationID = "concurrent-edit"
        assertCode("revisionConflict") { _ = try store!.commit(conflict) }
        var mismatch = request
        mismatch.changes["subject"] = .text("different")
        assertCode("operationMismatch") { _ = try store!.commit(mismatch) }
        store = nil
        try FileManager.default.removeItem(at: root.appendingPathComponent("index"))
        store = try ItemStore(root: root)
        XCTAssertEqual(try store!.get(first.itemID), second)
        XCTAssertEqual(try store!.commit(request).revision, second)
        XCTAssertEqual(files(root).count, 2)
    }

    func testIndexFailureDoesNotLoseCommitOrCauseDuplicateRetry() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        store.beforeIndexUpdate = { throw TractandaError("injected", "Index unavailable after publication") }
        let request = CommitRequest(
            classID: "Item", changes: ["body": .text("Still committed")], operationID: "index-failure")
        let result = try store.commit(request)
        XCTAssertFalse(result.isIndexReady)
        XCTAssertFalse(result.warnings.isEmpty)
        XCTAssertEqual(try store.get(result.revision.itemID), result.revision)
        XCTAssertTrue(try store.commit(request).wasReplayed)
        assertCode("indexUnavailable") { _ = try store.candidates() }
        store.beforeIndexUpdate = nil
        try store.rebuildIndex()
        XCTAssertEqual(try store.candidates(text: "still committed").map(\.itemID), [result.revision.itemID])
        XCTAssertEqual(files(root).count, 1)
    }

    func testRoleOwnFieldsLiveReferencesVacancyAndPrivacy() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        let ids = try DemoFixture.seed(store)
        let role = try store.get(ids["president"]!)
        let bob = try store.get(ids["bob"]!)
        func resolve(_ path: String, at: String = "2026-09-07T00:00:00Z", denied: Bool = false) throws
            -> Resolution
        {
            ItemPath.resolve(
                ItemReference(role.itemID), segments: try ItemPath.parse(path), at: Timestamp.parse(at)!
            ) { ref in
                if denied && ref.itemID != role.itemID { throw TractandaError("forbidden", "Private person") }
                return try store.get(ref.itemID, revisionID: ref.revisionID)
            }
        }
        XCTAssertTrue(ItemTypes.makeItem(from: role) is PersonItem)
        XCTAssertEqual(try resolve("holder.mobilePhone").value, bob.fields["mobilePhone"])
        let changedBob = try edit(store, bob, ["mobilePhone": .text("new private number")])
        XCTAssertEqual(try store.get(role.itemID).revisionID, role.revisionID)
        XCTAssertEqual(try resolve("holder.mobilePhone").value, .text("new private number"))
        let changedRole = try edit(store, role, ["phone": .text("new official number")])
        XCTAssertEqual(try store.get(bob.itemID).revisionID, changedBob.revisionID)
        XCTAssertEqual(try resolve("phone", denied: true).value, .text("new official number"))
        let privateResult = try resolve("holder.mobilePhone", denied: true)
        XCTAssertEqual(privateResult.status, .accessDenied)
        XCTAssertEqual(privateResult.visited.count, 1)
        XCTAssertEqual(try resolve("holder.mobilePhone", at: "2025-01-15T00:00:00Z").status, .unsetReference)
        XCTAssertEqual(try resolve("holder.displayName", at: "2024-12-31T23:59:59Z").value, .text("Alice"))
        XCTAssertEqual(try resolve("holder.displayName", at: "2025-02-01T00:00:00Z").value, .text("Bob"))
        _ = try edit(store, changedBob, [:], unset: ["mobilePhone"])
        XCTAssertEqual(try resolve("holder.mobilePhone").status, .unsetField)
        XCTAssertEqual(try resolve("mobilePhone").status, .unsetField)  // No holder fallback.
        let noTarget = ItemPath.resolve(ItemReference(role.itemID), segments: ["holder", "mobilePhone"]) {
            ref in
            if ref.itemID != role.itemID { throw TractandaError("notFound", "Missing canonical record") }
            return changedRole
        }
        XCTAssertEqual(noTarget.status, .resolutionError)
        XCTAssertEqual(noTarget.error?.code, "notFound")
    }

    func testCategoryPathManualDecisionsAndPortableQueryProfile() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        let ids = try DemoFixture.seed(store)
        let path = [ids["persons"]!, ids["family"]!, ids["alice"]!]
        XCTAssertEqual(try Categories.query(store: store, categoryPath: path).map(\.itemID), [ids["lunch"]!])
        let saved = try store.commit(
            CommitRequest(
                classID: "Item",
                changes: [
                    "subject": .text("Family and Alice"),
                    "viewDefinition": .object([
                        "language": .text(SpotlightQuery.profile),
                        "categoryPath": .list(path.map { .reference(ItemReference($0)) }),
                    ]),
                ], operationID: "saved-view")
        ).revision
        XCTAssertEqual(
            try Categories.savedView(store: store, id: saved.itemID).map(\.itemID), [ids["lunch"]!])
        let issue = try store.get(ids["issue"]!)
        let included = try edit(
            store, issue, ["categoryOverrides": .object([ids["family"]!: .text("include")])])
        XCTAssertEqual(
            Set(try Categories.query(store: store, categoryPath: path).map(\.itemID)),
            Set([ids["lunch"]!, issue.itemID]))
        XCTAssertEqual(
            try Categories.explain(included, category: store.get(ids["family"]!)).reason, "manual include")
        let excluded = try edit(
            store, included, ["categoryOverrides": .object([ids["family"]!: .text("exclude")])])
        XCTAssertEqual(try Categories.query(store: store, categoryPath: path).count, 1)
        _ = try edit(store, excluded, ["categoryOverrides": .object([:])])
        XCTAssertEqual(try Categories.query(store: store, categoryPath: path).count, 1)
        XCTAssertEqual(
            try Categories.query(store: store, expression: "kMDItemContentTypeTree == \"PersonItem\"").count,
            3)
        XCTAssertEqual(try store.candidates(text: "chess club").count, 3)
        let note = try store.commit(
            CommitRequest(
                classID: "Item",
                changes: [
                    "subject": .text("Frédéric's chess notes"),
                    "priority": .integer(3), "tags": .list([.text("Family"), .text("Chess")]),
                    "body": .text("Literal * symbol"),
                ], operationID: "unicode")
        ).revision
        let queries = [
            "kMDItemTitle ==[cd] \"FREDERIC*\" && priority >= 3",
            "(subject == \"wrong\" || tags ==[c] \"chess\") && priority < 4",
            "createdAt <= $time.now", "createdAt >= $time.iso(\"2001-01-01T00:00:00Z\")",
            "missing != *", "body == \"Literal \\* symbol\"",
        ]
        for query in queries { XCTAssertTrue(try SpotlightQuery(query).matches(note), query) }
        XCTAssertFalse(try SpotlightQuery("missing != \"anything\"").matches(note))
        XCTAssertFalse(try SpotlightQuery("tags !=[c] \"chess\"").matches(note))
        for invalid in [
            "subject MATCHES '.*'", "subject ==", "subject = 'x'", "(subject == 'x'", "holder.phone == '123'",
            "subject ==[z] 'x'", "priority > NaN",
        ] {
            assertCode("unsupportedQuery") { _ = try SpotlightQuery(invalid) }
        }
        assertCode("unsupportedQuery") {
            _ = try edit(
                store, note,
                [
                    "selection": .object([
                        "language": .text(SpotlightQuery.profile), "expression": .text("subject MATCHES 'x'"),
                    ])
                ])
        }
        try store.rebuildIndex()
        XCTAssertEqual(try Categories.query(store: store, categoryPath: path).map(\.itemID), [ids["lunch"]!])
        XCTAssertEqual(
            try Categories.savedView(store: store, id: saved.itemID).map(\.itemID), [ids["lunch"]!])
    }

    func testWriterExclusionAndDamagedRevisionRecovery() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        var store: ItemStore? = try ItemStore(root: root)
        assertCode("storeBusy") { _ = try ItemStore(root: root) }
        let first = try store!.commit(CommitRequest(classID: "Item", operationID: "first")).revision
        _ = try edit(store!, first, ["subject": .text("Second")])
        let firstPath = try XCTUnwrap(
            files(root).first { $0.lastPathComponent == first.revisionID + ".tractanda" })
        // A competing canonical successor must be diagnosed, never chosen by filename/date.
        var fields = first.fields
        fields["supersedes"] = .text(first.revisionID)
        fields["revisionID"] = .text(Identifier.make())
        fields["operationID"] = .text("competing")
        let branch = try Revision(fields: fields)
        let branchPath = firstPath.deletingLastPathComponent().appendingPathComponent(
            branch.revisionID + ".tractanda")
        try RecordCodec.encode(branch).write(to: branchPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: branchPath.path)
        store = nil
        assertCode("recoveryError") { _ = try ItemStore(root: root) }
        XCTAssertEqual(files(root).count, 3)  // Diagnosis leaves canonical evidence intact.
        try FileManager.default.removeItem(at: branchPath)
        store = try ItemStore(root: root)
        XCTAssertEqual(try store!.history(first.itemID).count, 2)
        store = nil
        try FileManager.default.removeItem(at: firstPath)
        assertCode("recoveryError") { _ = try ItemStore(root: root) }
    }

    func testAbandonedPublicationAndCorruptIndexRecovery() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        var store: ItemStore? = try ItemStore(root: root)
        let r = try store!.commit(CommitRequest(classID: "Item", operationID: "first")).revision
        let path = files(root)[0]
        let staged = path.appendingPathExtension("abc123")
        try Data("incomplete publication".utf8).write(to: staged)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
        store = nil
        try Data("broken database".utf8).write(to: root.appendingPathComponent("index/items.sqlite"))
        store = try ItemStore(root: root)
        XCTAssertEqual(try store!.get(r.itemID), r)
        XCTAssertEqual(store!.recoveryWarnings.count, 1)
        XCTAssertEqual(try store!.candidates().count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
    }

    func testRecoveryUsesPOSIXTraversalForNestedRecordsAndRejectsSymlinks() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        var store: ItemStore? = try ItemStore(root: root)
        let revision = try store!.commit(
            CommitRequest(
                classID: "Item", changes: ["subject": .text("nested")], operationID: "nested")
        ).revision
        let record = try XCTUnwrap(
            files(root).first { $0.lastPathComponent == revision.revisionID + ".tractanda" })
        let nested = root.appendingPathComponent("items/archive", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nested, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let nestedRecord = nested.appendingPathComponent(record.lastPathComponent)
        try FileManager.default.moveItem(at: record, to: nestedRecord)
        store = nil
        store = try ItemStore(root: root)
        XCTAssertEqual(try store!.get(revision.itemID), revision)

        store = nil
        let link = root.appendingPathComponent("items/forbidden-link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: nestedRecord.path)
        assertCode("recoveryError") { _ = try ItemStore(root: root) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
    }

    func testIntegerPrecisionAndFailedLiveRecovery() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        let first = try store.commit(
            CommitRequest(
                classID: "Item", changes: ["number": .integer(Int64.max)], operationID: "large-number")
        ).revision
        XCTAssertTrue(try SpotlightQuery("number == 9223372036854775807").matches(first))
        XCTAssertFalse(
            try SpotlightQuery("number == 9223372036854775807").matches(
                edit(store, first, ["number": .integer(Int64.max - 1)])))
        let unexpected = root.appendingPathComponent("items/unrecognized-record.txt")
        try Data("retain this for diagnosis".utf8).write(to: unexpected)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unexpected.path)
        assertCode("recoveryError") { try store.rebuildIndex() }
        assertCode("recoveryRequired") {
            _ = try store.commit(CommitRequest(classID: "Item", operationID: "must-not-write"))
        }
        assertCode("recoveryRequired") { _ = try store.get(first.itemID) }
        try FileManager.default.removeItem(at: unexpected)
        try store.rebuildIndex()
        XCTAssertEqual(try store.get(first.itemID).fields["number"], .integer(Int64.max - 1))
    }

    func testDiscardedIndexCompanionsAndInvalidEmptyCategoryQuery() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        var store: ItemStore? = try ItemStore(root: root)
        let first = try store!.commit(CommitRequest(classID: "Item", operationID: "note")).revision
        assertCode("notCategory") {
            _ = try Categories.query(
                store: store!, expression: "itemID == 'no-match'", categoryPath: [first.itemID])
        }
        store = nil
        for suffix in ["-journal", "-wal", "-shm"] {
            try Data("obsolete SQLite companion".utf8).write(
                to: root.appendingPathComponent("index/items.sqlite" + suffix))
        }
        store = try ItemStore(root: root)
        XCTAssertEqual(try store!.candidates().map(\.itemID), [first.itemID])
        for suffix in ["-journal", "-wal", "-shm"] {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("index/items.sqlite" + suffix).path))
        }
    }

    func testServiceBatchResultReferenceConflictsAndIdentityBoundary() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        _ = try DemoFixture.seed(store)
        let service = ItemService(store: store)
        func envelope(_ calls: [[Any]], uid: UInt32? = nil) throws -> [String: Any] {
            let data = try JSONSerialization.data(withJSONObject: [
                "using": [ItemService.capability], "methodCalls": calls,
            ])
            return try JSONSerialization.jsonObject(
                with: service.handle(data, peerUID: uid ?? store.ownerUID)) as! [String: Any]
        }
        let response = try envelope([
            [
                "TractandaItem/query",
                ["expression": "classID == \"Item\" && subject == \"Newsletter delivery issue\""], "q",
            ],
            [
                "TractandaItem/get",
                ["#ids": ["resultOf": "q", "name": "TractandaItem/query", "path": "/ids"]], "g",
            ],
            [
                "TractandaItem/get",
                ["#ids": ["resultOf": "missing", "name": "TractandaItem/query", "path": "/ids"]], "bad",
            ],
        ])
        let calls = response["methodResponses"] as! [[Any]]
        XCTAssertEqual(((calls[1][1] as! [String: Any])["list"] as! [Any]).count, 1)
        XCTAssertEqual((calls[2][1] as! [String: Any])["type"] as? String, "invalidResultReference")
        let denied = try envelope([["TractandaStore/info", [:], "i"]], uid: store.ownerUID &+ 1)
        XCTAssertEqual(denied["code"] as? String, "forbidden")
        let spoofed = try envelope([["TractandaItem/commit", ["actor": "uid:0"], "s"]])
        XCTAssertEqual(
            (((spoofed["methodResponses"] as! [[Any]])[0][1]) as! [String: Any])["type"] as? String,
            "invalidArguments")
        let unknown = try envelope([
            ["Unknown/method", [:], "u"], ["Core/echo", ["still": "running"], "ok"],
        ])
        XCTAssertEqual((unknown["methodResponses"] as! [[Any]])[1][0] as? String, "Core/echo")
    }

    func testRetrievalProjectionsByteContinuationDescribeAndInheritedWitness() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        let ids = try DemoFixture.seed(store)
        let oversized = try store.commit(
            CommitRequest(
                classID: "Item",
                changes: [
                    "subject": .text("Unicode 😀"),
                    "body": .text(String(repeating: "😀", count: 3_000)),
                    "customInt": .integer(Int64.max),
                ], operationID: "large-projection")
        ).revision
        let nearLimit = try store.commit(
            CommitRequest(
                classID: "Item",
                changes: ["body": .text(String(repeating: "😀", count: 1_500))],
                operationID: "near-limit-projection")
        ).revision
        let service = ItemService(store: store)
        func response(_ method: String, _ args: [String: Any]) throws -> [String: Any] {
            let data = try JSONSerialization.data(withJSONObject: [
                "using": [ItemService.capability], "methodCalls": [[method, args, "test"]],
            ])
            let result =
                try JSONSerialization.jsonObject(
                    with: service.handle(data, peerUID: store.ownerUID)) as! [String: Any]
            return (result["methodResponses"] as! [[Any]])[0][1] as! [String: Any]
        }
        let projected = try response(
            "TractandaItem/get",
            ["ids": [oversized.itemID], "properties": ["subject", "customInt"]])
        let projectedRecord = (projected["list"] as! [[String: Any]])[0]
        XCTAssertEqual(projectedRecord["formatVersion"] as? Int, 1)
        let fields = projectedRecord["fields"] as! [String: Any]
        XCTAssertNotNil(fields["itemID"])
        XCTAssertNotNil(fields["customInt"])
        XCTAssertNil(fields["body"])
        XCTAssertNil(fields["requestIdentity"])
        XCTAssertEqual(
            (try response(
                "TractandaItem/get",
                ["ids": [oversized.itemID], "properties": ["custom\\0"]]))["notFound"] as? [String], [])
        let nulProperty = try response(
            "TractandaItem/get", ["ids": [oversized.itemID], "properties": ["custom\0"]])
        XCTAssertEqual(nulProperty["type"] as? String, "invalidArguments")
        let bounded = try response(
            "TractandaItem/get",
            ["ids": [oversized.itemID], "projection": "content", "maxBytes": 8_192])
        XCTAssertEqual(bounded["oversizedIDs"] as? [String], [oversized.itemID])
        XCTAssertEqual(bounded["remainingIDs"] as? [String], [])
        XCTAssertEqual((bounded["list"] as? [Any])?.count, 0)
        let boundary = try response(
            "TractandaItem/get",
            [
                "ids": [nearLimit.itemID] + Array(repeating: nearLimit.itemID, count: 63),
                "projection": "content", "maxBytes": 8_192,
            ])
        XCTAssertEqual(boundary["type"] as? String, "responseTooLarge")
        let description = try response("TractandaStore/describe", ["topic": "types"])
        XCTAssertTrue(
            (description["types"] as? [[String: Any]])?.contains {
                $0["classID"] as? String == "Item"
            } == true)
        let classIDs = try XCTUnwrap(description["types"] as? [[String: Any]])
            .compactMap { $0["classID"] as? String }
        XCTAssertTrue(Set(classIDs).isDisjoint(with: ["NoteItem", "TodoItem", "PendencyItem", "ActionItem"]))
        let rootType = try XCTUnwrap(
            (description["types"] as? [[String: Any]])?.first {
                $0["classID"] as? String == "Item"
            })
        XCTAssertEqual(rootType["abstract"] as? Bool, false)
        XCTAssertTrue(rootType["parentID"] is NSNull)
        let overview = try response("TractandaStore/describe", [:])
        XCTAssertEqual(overview["currentUID"] as? UInt32, store.ownerUID)
        XCTAssertEqual(overview["ownerUID"] as? UInt32, store.ownerUID)
        let properties = try response("TractandaStore/describe", ["topic": "properties"])
        XCTAssertTrue(
            (properties["properties"] as? [[String: Any]])?.contains {
                $0["name"] as? String == "requestIdentity"
            } == true)
        _ = try edit(
            store, store.get(ids["persons"]!),
            [
                "selection": .object([
                    "language": .text(SpotlightQuery.profile), "expression": .text("subject == \"never\""),
                ])
            ])
        _ = try edit(
            store, store.get(ids["family"]!),
            [
                "selection": .object([
                    "language": .text(SpotlightQuery.profile), "expression": .text("subject == \"never\""),
                ]),
                "categoryParents": .list([.reference(ItemReference(ids["persons"]!))]),
            ])
        _ = try edit(
            store, store.get(ids["alice"]!),
            ["categoryParents": .list([.reference(ItemReference(ids["family"]!))])])
        let witness = try Categories.explain(
            store.get(ids["lunch"]!), category: store.get(ids["persons"]!), store: store)
        XCTAssertEqual(witness.inheritancePath?.first, ids["persons"])
        XCTAssertEqual(witness.inheritancePath, [ids["persons"]!, ids["family"]!, ids["alice"]!])
        XCTAssertEqual(witness.sourceReason, "selection rule")
    }

    func testActionAndWaitingCategoriesDoNotChangeItemType() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        func create(_ subject: String, fields: [String: ItemValue] = [:]) throws -> Revision {
            try store.commit(
                CommitRequest(
                    classID: "Item",
                    changes: fields.merging(["subject": .text(subject)]) { _, new in new },
                    operationID: Identifier.make())
            ).revision
        }
        let selection: ItemValue = .object([
            "language": .text(SpotlightQuery.profile), "expression": .text("itemID == \"\""),
        ])
        let todo = try create("To do", fields: ["selection": selection])
        let waiting = try create("Waiting", fields: ["selection": selection])
        let first = try create(
            "Ask for a date",
            fields: ["categoryOverrides": .object([todo.itemID: .text("include")])])
        XCTAssertTrue(try Categories.explain(first, category: todo, store: store).isIncluded)
        let second = try edit(
            store, first,
            [
                "waitingOn": .text("Waiting for the chair to respond"),
                "categoryOverrides": .object([
                    todo.itemID: .text("exclude"), waiting.itemID: .text("include"),
                ]),
            ])
        XCTAssertEqual(second.itemID, first.itemID)
        XCTAssertEqual(second.classID, "Item")
        XCTAssertFalse(try Categories.explain(second, category: todo, store: store).isIncluded)
        XCTAssertTrue(try Categories.explain(second, category: waiting, store: store).isIncluded)
        XCTAssertNil(first.fields["waitingOn"])
        XCTAssertEqual(try store.history(first.itemID).count, 2)
        assertCode("invalidWaitingOn") {
            _ = try edit(store, second, ["waitingOn": .integer(42)])
        }
        let event = try create("The chair's reply")
        let referenced = try edit(
            store, second, ["waitingOn": .reference(ItemReference(event.itemID))])
        XCTAssertEqual(referenced.fields["waitingOn"]?.link?.itemID, event.itemID)
        let ready = try edit(store, referenced, [:], unset: ["waitingOn"])
        XCTAssertNil(ready.fields["waitingOn"])
        XCTAssertEqual(ready.classID, "Item")
    }

    func testRetypeCopyTombstoneAndPreserveUnknownValues() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        let sourceBytes = Data("X-ACL: everyone\r\nFrom: example@example.invalid\r\n\r\nOriginal\0bytes".utf8)
        let first = try store.commit(
            CommitRequest(
                classID: "Item",
                changes: [
                    "subject": .text("Ask for date"),
                    "source": .bytes(sourceBytes), "custom.key": .object(["one": .integer(1)]),
                    "customList": .list([.boolean(false), .real(1.5)]),
                ], operationID: "todo")
        ).revision
        let retyped = try store.commit(
            CommitRequest(
                action: .retype, itemID: first.itemID, expectedRevisionID: first.revisionID,
                classID: "AppointmentItem", changes: ["subject": .text("Meeting with the chair")],
                operationID: "retype")
        ).revision
        XCTAssertEqual(first.itemID, retyped.itemID)
        XCTAssertTrue(ItemTypes.makeItem(from: retyped) is AppointmentItem)
        XCTAssertEqual(retyped.fields["custom.key"], first.fields["custom.key"])
        XCTAssertEqual(try ItemPath.parse("custom\\.key.one"), ["custom.key", "one"])
        let value = ItemPath.resolve(ItemReference(first.itemID), segments: ["custom.key", "one"]) {
            try store.get($0.itemID)
        }
        XCTAssertEqual(value.value, .integer(1))
        let copy = try store.commit(
            CommitRequest(
                action: .copy, itemID: first.itemID, expectedRevisionID: retyped.revisionID,
                operationID: "copy")
        ).revision
        XCTAssertNotEqual(copy.itemID, first.itemID)
        XCTAssertNil(copy.supersedes)
        XCTAssertEqual(try store.history(copy.itemID).count, 1)
        XCTAssertEqual(copy.fields["source"], .bytes(sourceBytes))
        let deleted = try edit(store, retyped, ["isDeleted": .boolean(true)])
        XCTAssertFalse(try store.candidates().contains { $0.itemID == deleted.itemID })
        XCTAssertEqual(try store.history(deleted.itemID).count, 3)
        let restored = try edit(store, deleted, ["isDeleted": .boolean(false)])
        XCTAssertEqual(restored.itemID, first.itemID)
        let unknown = try store.commit(
            CommitRequest(
                classID: "org.example.FutureItem", changes: ["opaque": .bytes(sourceBytes)],
                operationID: "unknown")
        ).revision
        XCTAssertEqual(try RecordCodec.decode(RecordCodec.encode(unknown)), unknown)
        XCTAssertEqual(ItemTypes.makeItem(from: unknown).revision.classID, "org.example.FutureItem")
        var record = try RecordCodec.encode(unknown)
        record.insert(contentsOf: Data("X-IsA: Evil\r\n".utf8), at: 0)
        assertCode("invalidRecord") { _ = try RecordCodec.decode(record) }
    }
}
