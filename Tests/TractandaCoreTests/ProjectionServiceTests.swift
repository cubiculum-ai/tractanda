import CTractandaPlatform
import XCTest

@testable import TractandaCore

final class ProjectionServiceTests: XCTestCase {
    private func folder() throws -> URL {
        try AttachmentFixtureCapacity.requireFree()
        return FileManager.default.temporaryDirectory.appendingPathComponent(
            "tractanda-projection-api-" + Identifier.make())
    }
    private func request(_ method: String, _ args: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "using": [ItemService.capability], "methodCalls": [[method, args, "c"]],
        ])
    }
    private func payload(_ data: Data) throws -> (String, [String: Any]) {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let calls = try XCTUnwrap(object["methodResponses"] as? [[Any]])
        let first = try XCTUnwrap(calls.first)
        return (try XCTUnwrap(first[0] as? String), try XCTUnwrap(first[1] as? [String: Any]))
    }
    private func call(_ service: ItemService, _ method: String, _ args: [String: Any]) throws -> [String: Any]
    {
        try payload(service.handle(request(method, args), peerUID: tractanda_uid())).1
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
        let ordinary = try JSON.decode(CommitResult.self, JSONSerialization.data(withJSONObject: result))
            .revision
        let edit = CommitRequest(
            action: .revise, itemID: ordinary.itemID, expectedRevisionID: ordinary.revisionID,
            changes: ["body": .text("edit")], operationID: Identifier.make())
        let editArgs = try XCTUnwrap(JSONSerialization.jsonObject(with: JSON.encode(edit)) as? [String: Any])
        let revised = try JSON.decode(
            CommitResult.self,
            JSONSerialization.data(withJSONObject: call(service, "TractandaItem/commit", editArgs))
        ).revision
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
            service, "TractandaItem/get", ["ids": ids, "maxBytes": 8192, "projection": "summary"])
        XCTAssertEqual((get["list"] as? [Any])?.count, 1)
        XCTAssertEqual((get["unresolved"] as? [[String: Any]])?.first?["itemID"] as? String, base.itemID)
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
        let data = try request("TractandaItem/get", ["ids": [other.itemID, base.itemID]])
        let prepared = try XCTUnwrap(service.preparePooledGet(data, peerUID: tractanda_uid()))
        let pool = try SQLiteReadPool(
            databaseURL: store.indexDirectory.appendingPathComponent("items.sqlite"))
        let records = try prepared.evaluate(in: pool)
        let response = try XCTUnwrap(
            service.finishPooledGet(prepared, records: records, peerUID: tractanda_uid()))
        let result = try payload(response).1
        XCTAssertEqual((result["list"] as? [Any])?.count, 1)
        XCTAssertEqual((result["unresolved"] as? [Any])?.count, 1)
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
        let data = try request("TractandaItem/history", ["itemID": base.itemID, "position": 0, "limit": 10])
        let prepared = try XCTUnwrap(service.preparePooledHistory(data, peerUID: tractanda_uid()))
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
        let data = try request("TractandaItem/get", ["ids": [item.itemID]])
        let prepared = try XCTUnwrap(service.preparePooledGet(data, peerUID: accounts.bob))
        let pool = try SQLiteReadPool(
            databaseURL: store.indexDirectory.appendingPathComponent("items.sqlite"))
        let records = try prepared.evaluate(in: pool)
        accounts.leaveTeam()
        XCTAssertEqual(try store.itemState(item.itemID).stateToken, token)
        XCTAssertNil(try service.finishPooledGet(prepared, records: records, peerUID: accounts.bob))
        let denied = try payload(service.handle(data, peerUID: accounts.bob)).1
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
        XCTAssertNotNil(result["revision"])
        let path = try call(service, "TractandaItem/resolve", ["itemID": base.itemID, "path": "subject"])
        XCTAssertNotEqual(path["type"] as? String, "unknownMethod")
    }
}
