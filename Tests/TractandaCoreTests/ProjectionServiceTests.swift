import CTractandaPlatform
import TractandaClient
import XCTest

@testable import TractandaCore

final class ProjectionServiceTests: XCTestCase {
    private func folder() throws -> URL {
        try AttachmentFixtureCapacity.requireFree()
        return FileManager.default.temporaryDirectory.appendingPathComponent(
            "tractanda-projection-api-" + Identifier.make())
    }
    private func request(_ store: ItemStore, _ method: String, _ args: [String: Any]) throws -> Data {
        try nativeFixtureRequest(
            method: method, arguments: args, accountID: store.nativeProtocolSessionBasis.identity, callID: "c"
        )
    }
    private func payload(_ data: Data) throws -> (String, [String: Any]) {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let calls = try XCTUnwrap(object["methodResponses"] as? [[Any]])
        let first = try XCTUnwrap(calls.first)
        return (try XCTUnwrap(first[0] as? String), try XCTUnwrap(first[1] as? [String: Any]))
    }
    private func payload(_ outcome: NativeMethodOutcome) throws -> (String, [String: Any]) {
        switch outcome {
        case .success(let replies, _):
            let reply = try XCTUnwrap(replies.first)
            return (
                reply.name,
                try XCTUnwrap(JSONSerialization.jsonObject(with: reply.arguments.encoded()) as? [String: Any])
            )
        case .failure(let error, _):
            return ("error", ["type": error.type, "description": error.description ?? ""])
        }
    }
    private func call(_ service: ItemService, _ method: String, _ args: [String: Any]) throws -> [String: Any]
    {
        try payload(
            service.handle(
                nativeFixtureRequest(
                    method: method, arguments: args,
                    accountID: service.store.nativeProtocolSessionBasis.identity),
                peerUID: tractanda_uid())
        ).1
    }
    private func conflictFixture() throws -> (URL, Revision, Revision, Revision) {
        let root = try folder()
        let base: Revision
        let itemDirectory: URL
        let origin: String
        do {
            let store = try ItemStore(root: root, revisionProjectionEnabled: true)
            base = try store.commit(
                .init(classID: "Item", changes: ["subject": .text("base")], operationID: Identifier.make())
            ).revision
            let row = try XCTUnwrap(
                store.exportCatalogueForVerification().first { $0.revisionID == base.revisionID })
            itemDirectory = root.appendingPathComponent(row.path).deletingLastPathComponent()
            origin = try XCTUnwrap(store.replicaID)
        }
        func branch(_ subject: String) throws -> Revision {
            var fields = base.fields
            let id = try UUID.makeVersion1().uuidString.lowercased()
            fields["revisionID"] = .text(id)
            fields["supersedes"] = .text(base.revisionID)
            fields["operationID"] = .text(id)
            fields["subject"] = .text(subject)
            fields["modifiedAt"] = .date(
                try RevisionPublicationClock.after([base.modifiedAt], now: { base.modifiedAt }))
            fields["revisionAncestry"] = try RevisionProvenance(
                kind: .authored, originReplicaID: origin,
                parents: [base.revisionID], writtenFields: ["subject"], unsetFields: [], frontier: []
            ).itemValue
            let value = try Revision(fields: fields, formatVersion: 2)
            let file = itemDirectory.appendingPathComponent(id + ".tractanda")
            try RecordCodec.encode(value).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
            return value
        }
        // Three tiny immutable records, estimated before the two bounded fixture writes.
        XCTAssertLessThan(3 * 16_384, Int(AttachmentFixtureCapacity.fixtureCapBytes))
        try AttachmentFixtureCapacity.requireFree(at: root)
        let a = try branch("A")
        let b = try branch("B")
        try StoreCheckpoint.markDirty(root: root)
        return (root, base, a, b)
    }
    func testFeatureRemainsConditionalAndOrdinaryCASContractUnchanged() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        let service = ItemService(store: store)
        let info = try call(service, "TractandaStore/info", [:])
        XCTAssertFalse(
            (info["features"] as? [String] ?? []).contains(ServerFeature.revisionProjection.rawValue))
        let state = try call(
            service, "TractandaItem/state", ["ids": [try UUID.makeVersion1().uuidString.lowercased()]])
        XCTAssertEqual(state["type"] as? String, "unsupportedFeature")
        let create = CommitRequest(
            classID: "Item", changes: ["subject": .text("ordinary")], operationID: Identifier.make())
        let createArgs = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSON.encode(create)) as? [String: Any])
        let result = try call(service, "TractandaItem/commit", createArgs)
        let receipt = try JSON.decode(MutationReceipt.self, JSONSerialization.data(withJSONObject: result))
        let ordinary = try store.get(receipt.itemID, revisionID: receipt.revisionID)
        let edit = CommitRequest(
            action: .revise, itemID: ordinary.itemID, expectedRevisionID: ordinary.revisionID,
            changes: ["body": .text("edit")], operationID: Identifier.make())
        let editArgs = try XCTUnwrap(JSONSerialization.jsonObject(with: JSON.encode(edit)) as? [String: Any])
        let revisedReceipt = try JSON.decode(
            MutationReceipt.self,
            JSONSerialization.data(withJSONObject: call(service, "TractandaItem/commit", editArgs))
        )
        let revised = try store.get(revisedReceipt.itemID, revisionID: revisedReceipt.revisionID)
        XCTAssertNotEqual(revised.revisionID, ordinary.revisionID)
    }
    func testMixedGetStateConflictDiscoveryAndSavedQueryCompleteness() throws {
        let (root, base, _, _) = try conflictFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root, revisionProjectionEnabled: true)
        let other = try store.commit(
            .init(
                classID: "Item", changes: ["subject": .text("ready"), "bucket": .integer(1)],
                operationID: Identifier.make())
        ).revision
        let view = try store.commit(
            .init(
                classID: "Item",
                changes: [
                    "viewDefinition": .object([
                        "language": .text(SpotlightQuery.profile), "expression": .text("bucket == 1"),
                    ])
                ], operationID: Identifier.make())
        ).revision
        let service = ItemService(store: store)
        let missing = try UUID.makeVersion1().uuidString.lowercased()
        let ids = [missing, base.itemID, other.itemID]
        let get = try call(
            service, "TractandaItem/getBounded", ["ids": ids, "maxBytes": 8192, "projection": "summary"])
        let encodedItems = try JSONSerialization.data(withJSONObject: get["list"]!)
        let items: [TractandaClient.JMAPItemRecord] = try JSONDecoder().decode(
            [TractandaClient.JMAPItemRecord].self, from: encodedItems)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.filter { $0.fields != nil }.map { $0.id }, [other.itemID])
        let unresolved = try XCTUnwrap(items.first { $0.id == base.itemID })
        XCTAssertEqual(unresolved.resolution?.status, .conflicted)
        XCTAssertNil(unresolved.fields)
        XCTAssertNil(unresolved.revisionID)
        XCTAssertEqual(get["notFound"] as? [String], [missing])
        XCTAssertEqual(get["remainingIDs"] as? [String], [])
        let states = try call(service, "TractandaItem/state", ["ids": ids])
        XCTAssertEqual((states["list"] as? [Any])?.count, 2)
        XCTAssertEqual(states["notFound"] as? [String], [missing])
        let conflicts = try call(service, "TractandaItem/conflicts", ["limit": 10])
        XCTAssertEqual((conflicts["list"] as? [[String: Any]])?.first?["itemID"] as? String, base.itemID)
        for args: [String: Any] in [[:], ["viewID": view.itemID], ["expression": "bucket == 1"]] {
            let query = try call(service, "TractandaItem/query", args)
            XCTAssertEqual(query["completeness"] as? String, "unresolvedItems")
            XCTAssertEqual(query["conflictsAvailable"] as? Bool, true)
            XCTAssertFalse((query["ids"] as? [String] ?? []).contains(base.itemID))
        }
    }
    func testPooledGetCarriesMixedOutcomesAndRechecksTokensBeforeDelivery() throws {
        let (root, base, _, _) = try conflictFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root, revisionProjectionEnabled: true)
        let other = try store.commit(
            .init(classID: "Item", changes: ["subject": .text("ready")], operationID: Identifier.make())
        ).revision
        let service = ItemService(store: store)
        let data = try request(store, "TractandaItem/get", ["ids": [other.itemID, base.itemID]])
        let prepared = try XCTUnwrap(
            service.preparePooledGet(nativeFixtureInvocation(data), peerUID: tractanda_uid()))
        let pool = try SQLiteReadPool(
            databaseURL: store.indexDirectory.appendingPathComponent("items.sqlite"))
        let records = try prepared.evaluate(in: pool)
        let response = try XCTUnwrap(
            service.finishPooledGet(prepared, records: records, peerUID: tractanda_uid()))
        let result = try payload(response).1
        let encodedItems = try JSONSerialization.data(withJSONObject: result["list"]!)
        let items: [TractandaClient.JMAPItemRecord] = try JSONDecoder().decode(
            [TractandaClient.JMAPItemRecord].self, from: encodedItems)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.filter { $0.fields != nil }.map { $0.id }, [other.itemID])
        let unresolved = try XCTUnwrap(items.first { $0.id == base.itemID })
        XCTAssertEqual(unresolved.resolution?.status, .conflicted)
        XCTAssertNil(unresolved.fields)
        XCTAssertNil(unresolved.revisionID)
        let state = try store.itemState(base.itemID)
        _ = try store.resolveConflict(
            .init(
                itemID: base.itemID, expectedStateToken: state.stateToken,
                reviewedFrontier: try XCTUnwrap(state.frontier), changes: ["subject": .text("resolved")],
                unset: [], operationID: Identifier.make()))
        XCTAssertNil(try service.finishPooledGet(prepared, records: records, peerUID: tractanda_uid()))
    }
    func testPooledHistoryIncludesAllPhysicalForkRowsInTimestampOrder() throws {
        let (root, base, a, b) = try conflictFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root, revisionProjectionEnabled: true)
        let service = ItemService(store: store)
        let data = try request(
            store, "TractandaItem/history", ["itemID": base.itemID, "position": 0, "limit": 10])
        let prepared = try XCTUnwrap(
            service.preparePooledHistory(nativeFixtureInvocation(data), peerUID: tractanda_uid()))
        let pool = try SQLiteReadPool(
            databaseURL: store.indexDirectory.appendingPathComponent("items.sqlite"))
        let page = try prepared.evaluate(in: pool)
        XCTAssertEqual(page.total, 3)
        XCTAssertEqual(
            page.records.map { $0.revision.revisionID },
            [a.revisionID, b.revisionID].sorted(by: >) + [base.revisionID])
        XCTAssertNotNil(try service.finishPooledHistory(prepared, result: page, peerUID: tractanda_uid()))
    }
    private final class Accounts: AccountDirectory, @unchecked Sendable {
        let lock = NSLock()
        let owner = tractanda_uid()
        let bob: UInt32 = 51_002
        var member = true
        func leaveTeam() {
            lock.lock()
            member = false
            lock.unlock()
        }
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            lock.lock()
            defer { lock.unlock() }
            if uid == owner {
                return .init(uid: owner, name: "owner", primaryGroupName: "team", groupIDs: [10, 20])
            }
            if uid == bob {
                return .init(
                    uid: bob, name: "bob", primaryGroupName: "readers", groupIDs: member ? [10, 30] : [30])
            }
            throw TractandaError("unresolvedPrincipal", "Unknown fixture user")
        }
        func user(named name: String) throws -> AccountIdentity {
            if name == "owner" { return try user(forUID: owner) }
            if name == "bob" { return try user(forUID: bob) }
            throw TractandaError("unresolvedPrincipal", "Unknown fixture user")
        }
        func groupID(named name: String) throws -> UInt32 {
            guard let id: UInt32 = ["team": 10, "operators": 20, "readers": 30][name] else {
                throw TractandaError("unresolvedPrincipal", "Unknown fixture group")
            }
            return id
        }
    }
    func testPooledDeliveryRefreshesGroupAuthorityWhenItemTokenDoesNotChange() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = Accounts()
        let store = try ItemStore(root: root, accounts: accounts, revisionProjectionEnabled: true)
        let configuration: ItemValue = .object([
            "profile": .text(AccessConfiguration.profile),
            "groups": .list([.text("team"), .text("readers")]), "administration": .text("system"),
            "administratorGroup": .text("operators"), "legacyUsers": .object([:]),
        ])
        _ = try store.commit(
            .init(
                classID: "AccessConfigurationItem", changes: ["accessConfiguration": configuration],
                operationID: Identifier.make()))
        let permissions: ItemValue = .object([
            "profile": .text(ItemPermissions.profile), "owner": .text("owner"),
            "group": .text("team"), "mode": .integer(0o640), "acl": .object([:]),
        ])
        let item = try store.commit(
            .init(
                classID: "Item", changes: ["subject": .text("group private"), "permissions": permissions],
                operationID: Identifier.make())
        ).revision
        let token = try store.itemState(item.itemID).stateToken
        let service = ItemService(store: store)
        let data = try request(store, "TractandaItem/get", ["ids": [item.itemID]])
        let prepared = try XCTUnwrap(
            service.preparePooledGet(nativeFixtureInvocation(data), peerUID: accounts.bob))
        let pool = try SQLiteReadPool(
            databaseURL: store.indexDirectory.appendingPathComponent("items.sqlite"))
        let records = try prepared.evaluate(in: pool)
        accounts.leaveTeam()
        XCTAssertEqual(try store.itemState(item.itemID).stateToken, token)
        XCTAssertNil(try service.finishPooledGet(prepared, records: records, peerUID: accounts.bob))
        let denied = try payload(
            service.handle(
                readWireRequest(store, "TractandaItem/get", ["ids": [item.itemID]]), peerUID: accounts.bob)
        ).1
        XCTAssertEqual(denied["notFound"] as? [String], [item.itemID])
        XCTAssertEqual((denied["list"] as? [Any])?.count, 0)
    }

    func testResolveConflictIsDistinctFromReferencePathResolution() throws {
        let (root, base, _, _) = try conflictFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root, revisionProjectionEnabled: true)
        let service = ItemService(store: store)
        let state = try store.itemState(base.itemID)
        let resolution = ResolveConflictRequest(
            itemID: base.itemID, expectedStateToken: state.stateToken,
            reviewedFrontier: try XCTUnwrap(state.frontier), changes: ["subject": .text("chosen")], unset: [],
            operationID: Identifier.make())
        let args = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSON.encode(resolution)) as? [String: Any])
        let result = try call(service, "TractandaItem/resolveConflict", args)
        XCTAssertNotNil(result["revisionId"])
        XCTAssertNil(result["revision"])
        XCTAssertNil(result["itemState"])
        let path = try call(service, "TractandaItem/resolve", ["itemID": base.itemID, "path": "subject"])
        XCTAssertNotEqual(path["type"] as? String, "unknownMethod")
    }
}

extension ProjectionServiceTests {
    private func readWireRequest(_ store: ItemStore, _ method: String, _ arguments: [String: Any]) throws
        -> Data
    {
        var args = arguments
        args["accountId"] = try store.nativeProtocolSessionBasis.identity
        return try JSONSerialization.data(withJSONObject: [
            "using": ["urn:ietf:params:jmap:core", ItemService.capability],
            "methodCalls": [[method, args, "read"]],
        ])
    }
    func testJMAPReadCollectionsPropertiesAndExactRevisionIdentity() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root, revisionProjectionEnabled: true)
        let first = try store.commit(
            .init(
                classID: "Item", changes: ["subject": .text("before"), "wide": .integer(.max)],
                operationID: Identifier.make()), actorUID: tractanda_uid()
        ).revision
        let second = try store.commit(
            .init(
                action: .revise, itemID: first.itemID, expectedRevisionID: first.revisionID,
                changes: ["subject": .text("after")], operationID: Identifier.make()),
            actorUID: tractanda_uid()
        ).revision
        let service = ItemService(store: store)
        let missing = Identifier.make()
        let item = try payload(
            service.handle(
                readWireRequest(
                    store, "TractandaItem/get",
                    [
                        "ids": [first.itemID, first.itemID, missing],
                        "properties": ["id", "revisionId", "fields"], "fieldProperties": ["wide"],
                    ]), peerUID: tractanda_uid())
        ).1
        let list = try XCTUnwrap(item["list"] as? [[String: Any]])
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0]["id"] as? String, first.itemID)
        XCTAssertEqual(list[0]["revisionId"] as? String, second.revisionID)
        XCTAssertNil(list[0]["formatVersion"])
        let fields = try XCTUnwrap(list[0]["fields"] as? [String: [String: Any]])
        XCTAssertEqual(fields["wide"]?["value"] as? String, String(Int64.max))
        XCTAssertNil(fields["subject"])
        XCTAssertEqual(item["notFound"] as? [String], [missing])
        let unknowns = ["valid_Unknown-ID", first.itemID.uppercased()]
        let unknown = try payload(
            service.handle(
                readWireRequest(store, "TractandaItem/get", ["ids": unknowns]), peerUID: tractanda_uid())
        ).1
        XCTAssertEqual(unknown["notFound"] as? [String], unknowns)
        let malformed = try payload(
            service.handle(
                readWireRequest(store, "TractandaItem/get", ["ids": [17]]), peerUID: tractanda_uid())
        ).1
        XCTAssertEqual(malformed["type"] as? String, "invalidArguments")

        XCTAssertEqual(item["accountId"] as? String, try store.nativeProtocolSessionBasis.identity)
        let revisions = try payload(
            service.handle(
                readWireRequest(
                    store, "TractandaRevision/get", ["ids": [first.revisionID, second.revisionID, missing]]),
                peerUID: tractanda_uid())
        ).1
        let records = try XCTUnwrap(revisions["list"] as? [[String: Any]])
        XCTAssertEqual(records.compactMap { $0["id"] as? String }, [first.revisionID, second.revisionID])
        XCTAssertEqual(records.compactMap { $0["itemId"] as? String }, [first.itemID, first.itemID])
        XCTAssertEqual(revisions["notFound"] as? [String], [missing])
        let history = try payload(
            service.handle(
                readWireRequest(store, "TractandaItem/history", ["itemID": first.itemID]),
                peerUID: tractanda_uid())
        ).1
        XCTAssertEqual(
            Set((history["list"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }),
            Set([first.revisionID, second.revisionID]))
    }
    func testJMAPQueryStandardPositionsAnchorZeroAndTotals() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root, revisionProjectionEnabled: true)
        var ids: [String] = []
        for title in ["A", "B", "C"] {
            ids.append(
                try store.commit(
                    .init(
                        classID: "Item", changes: ["subject": .text(title)], operationID: Identifier.make()),
                    actorUID: tractanda_uid()
                ).revision.itemID)
        }
        let service = ItemService(store: store)
        let sort: [[String: Any]] = [["property": "subject", "isAscending": true]]
        func query(_ args: [String: Any]) throws -> [String: Any] {
            var args = args
            args["sort"] = sort
            return try payload(
                service.handle(readWireRequest(store, "TractandaItem/query", args), peerUID: tractanda_uid())
            ).1
        }
        let last = try query(["position": -1, "calculateTotal": true])
        XCTAssertEqual(last["ids"] as? [String], [ids[2]])
        XCTAssertEqual(last["position"] as? Int, 2)
        XCTAssertEqual(last["total"] as? Int, 3)
        XCTAssertEqual(last["canCalculateChanges"] as? Bool, false)
        let anchored = try query(["anchor": ids[1], "anchorOffset": -1, "limit": 2])
        XCTAssertEqual(anchored["ids"] as? [String], Array(ids.prefix(2)))
        XCTAssertNil(anchored["total"])
        XCTAssertEqual(
            try query(["anchor": ids[1], "position": 99, "limit": 1])["ids"] as? [String], [ids[1]])
        XCTAssertEqual(try query(["anchorOffset": 99, "limit": 1])["ids"] as? [String], [ids[0]])
        XCTAssertEqual(try query(["anchor": NSNull(), "position": -1])["ids"] as? [String], [ids[2]])
        let beyond = try query(["anchor": ids[1], "anchorOffset": 9_007_199_254_740_991])
        XCTAssertEqual(beyond["ids"] as? [String], [])
        XCTAssertEqual(beyond["position"] as? Int, 3)
        let before = try query(["anchor": ids[1], "anchorOffset": -9_007_199_254_740_991, "limit": 1])
        XCTAssertEqual(before["ids"] as? [String], [ids[0]])
        XCTAssertEqual(before["position"] as? Int, 0)
        let farPosition = try query(["position": 9_007_199_254_740_991])
        XCTAssertEqual(farPosition["ids"] as? [String], [])
        XCTAssertEqual(farPosition["position"] as? Int, 9_007_199_254_740_991)

        let zero = try query(["limit": 0, "calculateTotal": true])
        XCTAssertEqual(zero["ids"] as? [String], [])
        XCTAssertEqual(zero["total"] as? Int, 3)
        let early = try query([
            "filter": ["expression": "modifiedAt < $time.today", "at": "2020-01-01T00:00:00Z"]
        ])
        let later = try query([
            "filter": ["expression": "modifiedAt < $time.today", "at": "2030-01-01T00:00:00Z"]
        ])
        XCTAssertEqual(early["ids"] as? [String], [])
        XCTAssertEqual((later["ids"] as? [String])?.count, 3)
        XCTAssertNotEqual(early["queryState"] as? String, later["queryState"] as? String)

        XCTAssertEqual(try query(["anchor": Identifier.make()])["type"] as? String, "anchorNotFound")
        XCTAssertEqual(
            try query(["filter": ["operator": "OR", "conditions": []]])["type"] as? String,
            "unsupportedFilter")
    }
    func testJMAPTaggedWriteRetryKeepsCanonicalIdentityAndEchoExact() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root, revisionProjectionEnabled: true)
        let service = ItemService(store: store)
        let operation = Identifier.make()
        let args: [String: Any] = [
            "action": "create", "classID": "Item", "operationID": operation, "unset": [String](),
            "changes": [
                "subject": ["type": "text", "value": "wide"],
                "wide": ["type": "integer", "value": String(Int64.max)],
                "low": ["type": "integer", "value": String(Int64.min)],
            ],
        ]
        let request = try readWireRequest(store, "TractandaItem/commit", args)
        var malformed = args
        malformed.removeValue(forKey: "unset")
        let rejected = try payload(
            service.handle(
                readWireRequest(store, "TractandaItem/commit", malformed), peerUID: tractanda_uid())
        ).1
        XCTAssertEqual(rejected["type"] as? String, "invalidArguments")
        let receipt = try payload(service.handle(request, peerUID: tractanda_uid())).1
        XCTAssertNil(receipt["type"])
        let itemID = try XCTUnwrap(receipt["itemId"] as? String)
        let revisionID = try XCTUnwrap(receipt["revisionId"] as? String)
        let original = try store.get(itemID, revisionID: revisionID)
        XCTAssertEqual(original.fields["wide"], .integer(.max))
        XCTAssertEqual(original.fields["low"], .integer(.min))
        let replay = try payload(service.handle(request, peerUID: tractanda_uid())).1
        XCTAssertEqual(replay["revisionId"] as? String, revisionID)
        XCTAssertEqual(replay["replayed"] as? Bool, true)
        XCTAssertEqual(try store.get(itemID).fields["requestIdentity"], original.fields["requestIdentity"])
        let echo = try JSONSerialization.data(withJSONObject: [
            "using": ["urn:ietf:params:jmap:core"],
            "methodCalls": [
                ["Core/echo", ["itemID": "#unknown", "changes": ["type": "integer", "value": 42]], "e"]
            ],
        ])
        let echoed = try payload(service.handle(echo, peerUID: tractanda_uid())).1
        XCTAssertEqual(echoed["itemID"] as? String, "#unknown")
    }
}

extension ProjectionServiceTests {
    func testJMAPReadUnresolvedIsIdentifiedWithoutRepresentativeContent() throws {
        let (root, base, _, _) = try conflictFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root, revisionProjectionEnabled: true)
        let service = ItemService(store: store)
        let value = try payload(
            service.handle(
                readWireRequest(store, "TractandaItem/get", ["ids": [base.itemID]]), peerUID: tractanda_uid())
        ).1
        let list = try XCTUnwrap(value["list"] as? [[String: Any]])
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0]["id"] as? String, base.itemID)
        XCTAssertTrue(list[0]["revisionId"] is NSNull)
        XCTAssertTrue(list[0]["fields"] is NSNull)
        XCTAssertTrue(list[0]["formatVersion"] is NSNull)
        XCTAssertNotNil(list[0]["resolution"])
        XCTAssertEqual(value["notFound"] as? [String], [])
        XCTAssertNil(value["unresolved"])
    }
    func testJMAPBoundedGetExplicitContinuationAndStandardGetValidation() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root, revisionProjectionEnabled: true)
        let revision = try store.commit(
            .init(
                classID: "Item",
                changes: ["subject": .text("large"), "body": .text(String(repeating: "x", count: 20_000))],
                operationID: Identifier.make()), actorUID: tractanda_uid()
        ).revision
        let service = ItemService(store: store)
        func call(_ method: String, _ args: [String: Any]) throws -> [String: Any] {
            try payload(service.handle(readWireRequest(store, method, args), peerUID: tractanda_uid())).1
        }
        let bounded = try call("TractandaItem/getBounded", ["ids": [revision.itemID], "maxBytes": 8192])
        XCTAssertEqual(bounded["oversizedIDs"] as? [String], [revision.itemID])
        XCTAssertEqual(bounded["remainingIDs"] as? [String], [])
        let complete = try call("TractandaItem/get", ["ids": [revision.itemID]])
        XCTAssertEqual((complete["list"] as? [Any])?.count, 1)
        XCTAssertNil(complete["remainingIDs"])
        XCTAssertEqual(
            try call("TractandaItem/get", ["ids": [revision.itemID], "maxBytes": 8192])["type"] as? String,
            "invalidArguments")
        XCTAssertEqual(
            try call("TractandaItem/get", ["ids": NSNull()])["type"] as? String, "invalidArguments")
        XCTAssertEqual(
            try call("TractandaItem/get", ["ids": (0..<65).map { _ in Identifier.make() }])["type"]
                as? String, "requestTooLarge")
    }
}

extension ProjectionServiceTests {
    func testJMAPOptimizedQueryAndGetUseSameWireProjection() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let account: String
        let revision: Revision
        do {
            let store = try ItemStore(root: root, revisionProjectionEnabled: true)
            revision = try store.commit(
                .init(
                    classID: "Item", changes: ["subject": .text("pooled"), "wide": .integer(.max)],
                    operationID: Identifier.make()), actorUID: tractanda_uid()
            ).revision
            account = try store.nativeProtocolSessionBasis.identity
        }
        let coordinator = try await ServiceCoordinator(
            opening: root, embeddingProviderForTesting: nil, revisionProjectionEnabledForTesting: true)
        let pooled = expectation(description: "shared-schema query uses pooled lease")
        await coordinator.setPooledReadLeaseHookForTesting { pooled.fulfill() }
        func request(_ method: String, _ args: [String: Any]) throws -> Data {
            var args = args
            args["accountId"] = account
            return try JSONSerialization.data(withJSONObject: [
                "using": ["urn:ietf:params:jmap:core", ItemService.capability],
                "methodCalls": [[method, args, "async"]],
            ])
        }
        do {
            let response = try await coordinator.handle(
                request(
                    "TractandaItem/query",
                    ["filter": ["expression": "classID == \"Item\""], "calculateTotal": true]),
                forUID: tractanda_uid())
            let result = try payload(response).1
            XCTAssertEqual(result["ids"] as? [String], [revision.itemID])
            XCTAssertEqual(result["total"] as? Int, 1)
            XCTAssertEqual(result["canCalculateChanges"] as? Bool, false)
            XCTAssertEqual(result["accountId"] as? String, account)
            await fulfillment(of: [pooled], timeout: 10)
            await coordinator.setPooledReadLeaseHookForTesting(nil)
            let get = try await coordinator.handle(
                request(
                    "TractandaItem/get",
                    ["ids": [revision.itemID], "properties": ["id", "fields"], "fieldProperties": ["wide"]]),
                forUID: tractanda_uid())
            let record = try XCTUnwrap((payload(get).1["list"] as? [[String: Any]])?.first)
            XCTAssertEqual(record["id"] as? String, revision.itemID)
            XCTAssertNil(record["revisionId"])
            XCTAssertEqual(
                (record["fields"] as? [String: [String: Any]])?["wide"]?["value"] as? String,
                String(Int64.max))
            await coordinator.close()
        } catch {
            await coordinator.close()
            throw error
        }
    }
}

extension ProjectionServiceTests {
    func testJMAPRevisionAndHistoryUseFreshCurrentACL() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = Accounts()
        let store = try ItemStore(root: root, accounts: accounts, revisionProjectionEnabled: true)
        let configuration: ItemValue = .object([
            "profile": .text(AccessConfiguration.profile),
            "groups": .list([.text("team"), .text("readers")]), "administration": .text("system"),
            "administratorGroup": .text("operators"), "legacyUsers": .object([:]),
        ])
        _ = try store.commit(
            .init(
                classID: "AccessConfigurationItem", changes: ["accessConfiguration": configuration],
                operationID: Identifier.make()))
        let permissions: ItemValue = .object([
            "profile": .text(ItemPermissions.profile), "owner": .text("owner"), "group": .text("team"),
            "mode": .integer(0o640), "acl": .object([:]),
        ])
        let revision = try store.commit(
            .init(
                classID: "Item", changes: ["subject": .text("private history"), "permissions": permissions],
                operationID: Identifier.make())
        ).revision
        let service = ItemService(store: store)
        func call(_ method: String, _ args: [String: Any]) throws -> [String: Any] {
            try payload(service.handle(readWireRequest(store, method, args), peerUID: accounts.bob)).1
        }
        XCTAssertEqual(
            (try call("TractandaItem/history", ["itemID": revision.itemID])["list"] as? [Any])?.count, 1)
        XCTAssertEqual(
            (try call("TractandaRevision/get", ["ids": [revision.revisionID]])["list"] as? [Any])?.count, 1)
        accounts.leaveTeam()
        XCTAssertEqual(
            try call("TractandaItem/history", ["itemID": revision.itemID])["type"] as? String, "forbidden")
        let denied = try call("TractandaRevision/get", ["ids": [revision.revisionID]])
        XCTAssertEqual(denied["notFound"] as? [String], [revision.revisionID])
        XCTAssertEqual((denied["list"] as? [Any])?.count, 0)
    }
}
