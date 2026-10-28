import CTractandaPlatform
import XCTest

@testable import TractandaCore

final class ClusterBoundaryRepairTests: XCTestCase {
    private final class Accounts: AccountDirectory {
        let owner = AccountIdentity(
            uid: tractanda_uid(), name: "owner", primaryGroupName: "staff", groupIDs: [70001])
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            guard uid == owner.uid else {
                throw TractandaError("unresolvedPrincipal", "Unknown fixture user")
            }
            return owner
        }
        func user(named name: String) throws -> AccountIdentity {
            guard name == "owner" else { throw TractandaError("unresolvedPrincipal", "Unknown fixture user") }
            return owner
        }
        func groupID(named name: String) throws -> UInt32 { 70001 }
    }

    private func root() throws -> URL {
        try AttachmentFixtureCapacity.requireFree()
        return FileManager.default.temporaryDirectory.appendingPathComponent(
            "tractanda-boundary-" + Identifier.make())
    }

    private func publishFixture(_ revision: Revision, root: URL) throws -> URL {
        let path = root.appendingPathComponent("items/2026/10/13/12/00/\(revision.itemID)")
        try FileManager.default.createDirectory(
            at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = path.appendingPathComponent(revision.revisionID + ".tractanda")
        try RecordCodec.encode(revision).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
        try StoreCheckpoint.markDirty(root: root)
        return file
    }

    private func shadow(_ revision: Revision, actor: String, request: CommitRequest, modern: Bool) throws
        -> Revision
    {
        var fields = revision.fields
        fields["itemID"] = .text(try UUID.makeVersion1().uuidString.lowercased())
        fields["revisionID"] = .text(try UUID.makeVersion1().uuidString.lowercased())
        fields["actor"] = .text(actor)
        fields["operationID"] = .text(request.operationID)
        fields["requestIdentity"] = .text(try JSON.encode(request).base64EncodedString())
        if !modern { fields.removeValue(forKey: "revisionAncestry") }
        return try Revision(fields: fields, formatVersion: modern ? 2 : 1)
    }

    func testCurrentPrincipalLocalReceiptPrecedesLegacyAndAliasCollisionRemainsClosed() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = Accounts()
        let request = CommitRequest(
            classID: "Item", changes: ["subject": .text("modern")], operationID: "shared")
        let original: Revision
        do {
            let store = try ItemStore(root: root, accounts: accounts)
            _ = try store.configureAccess(
                .object([
                    "profile": .text(AccessConfiguration.profile), "administration": .text("serviceOwner"),
                    "users": .list([.text("owner")]),
                    "userAliases": .object(["historic-owner": .text("owner")]),
                ]), operationID: "access")
            original = try store.commit(request).revision
        }
        let legacy = try shadow(original, actor: "user:historic-owner", request: request, modern: false)
        _ = try publishFixture(legacy, root: root)
        do {
            let store = try ItemStore(root: root, accounts: accounts)
            XCTAssertEqual(try store.commit(request).revision, original)
            XCTAssertEqual(try store.get(legacy.itemID), legacy)
        }
        let alias = try shadow(original, actor: "user:historic-owner", request: request, modern: true)
        _ = try publishFixture(alias, root: root)
        let store = try ItemStore(root: root, accounts: accounts)
        XCTAssertThrowsError(try store.commit(request)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "operationMismatch")
        }
        XCTAssertEqual(try store.get(alias.itemID), alias)
    }

    func testGraphAndCatalogueResourceReasonsSurviveStoreAndPreserveCanonicalBytes() throws {
        for insertion in [false, true] {
            let root = try root()
            defer { try? FileManager.default.removeItem(at: root) }
            let record: Revision
            do {
                let store = try ItemStore(root: root)
                record = try store.commit(CommitRequest(classID: "Item", operationID: "create")).revision
                for number in 0..<7 {
                    _ = try store.commit(CommitRequest(classID: "Item", operationID: "extra-\(number)"))
                }
                let row = try XCTUnwrap(
                    store.exportCatalogueForVerification().first { $0.revisionID == record.revisionID })
                let file = store.root.appendingPathComponent(row.path)
                let before = try Data(contentsOf: file)
                if insertion {
                    store.recoveryCatalogueForTesting = { $0.graphReserveBytes = UInt64.max }
                } else {
                    store.beforeRevisionGraphValidationForTesting = { $0.graphMaximumTemporaryBytes = 1 }
                }
                XCTAssertThrowsError(try store.rebuildIndex()) {
                    XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
                }
                XCTAssertTrue(StoreCheckpoint.isDirty(root: root))
                XCTAssertEqual(try Data(contentsOf: file), before)
            }
            let recovered = try ItemStore(root: root)
            XCTAssertEqual(try recovered.get(record.itemID), record)
            XCTAssertFalse(StoreCheckpoint.isDirty(root: root))
        }
    }

    func testValidUnsupportedResolutionReportsProjectionRequiredRatherThanCorruption() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let first: Revision
        do {
            let store = try ItemStore(root: root)
            first = try store.commit(CommitRequest(classID: "Item", operationID: "create")).revision
        }
        var fields = first.fields
        fields["revisionID"] = .text(try UUID.makeVersion1().uuidString.lowercased())
        fields["supersedes"] = .text(first.revisionID)
        fields["modifiedAt"] = .date(
            try RevisionMerge.timestamp(after: [first.modifiedAt], now: { first.modifiedAt }))
        fields["operationID"] = .text("resolution")
        fields["revisionAncestry"] = try RevisionProvenance(
            kind: .resolution, originReplicaID: first.provenance!.originReplicaID,
            parents: [first.revisionID], writtenFields: [], unsetFields: [], frontier: [first.revisionID]
        ).itemValue
        let resolution = try Revision(fields: fields, formatVersion: 2)
        let file = try publishFixture(resolution, root: root)
        let originalBytes = try Data(contentsOf: file)
        XCTAssertThrowsError(try ItemStore(root: root)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "revisionProjectionRequired")
        }
        XCTAssertEqual(try Data(contentsOf: file), originalBytes)
    }

    func testWideFormatTwoRecordSucceedsThroughActualPooledHistory() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        var fields: [String: ItemValue] = [:]
        for number in 0..<40 {
            fields["property\(number)-" + String(repeating: "x", count: 80)] = .text("value")
        }
        let record = try store.commit(CommitRequest(classID: "Item", changes: fields, operationID: "wide"))
            .revision
        XCTAssertGreaterThan(try JSON.encode(record.provenance!.itemValue).count, 2048)
        let service = ItemService(store: store)
        let request = try nativeFixtureEnvelope(
            calls: [["TractandaItem/history", ["itemID": record.itemID, "limit": 1], "history"]],
            accountID: store.nativeProtocolSessionBasis.identity)
        let prepared = try XCTUnwrap(
            service.preparePooledHistory(nativeFixtureInvocation(request), peerUID: tractanda_uid()))
        let pool = try SQLiteReadPool(
            databaseURL: store.indexDirectory.appendingPathComponent("items.sqlite"))
        defer { try? pool.shutdown() }
        let result = try prepared.evaluate(in: pool)
        XCTAssertEqual(result.records.map(\.revision), [record])
        XCTAssertNotNil(try service.finishPooledHistory(prepared, result: result, peerUID: tractanda_uid()))
    }
}
