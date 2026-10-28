import CTractandaPlatform
import Foundation
import TractandaClient
import XCTest

@testable import TractandaCore

final class JMAPNativeBoundaryTests: XCTestCase {
    private final class Accounts: AccountDirectory, @unchecked Sendable {
        let alice: UInt32 = 52091
        private let lock = NSLock()
        private var revoked = false
        func revokeAlice() { lock.withLock { revoked = true } }
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            let name: String
            if uid == tractanda_uid() {
                name = "owner"
            } else if uid == alice {
                guard !lock.withLock({ revoked }) else {
                    throw TractandaError("forbidden", "Fixture account revoked.")
                }
                name = "alice"
            } else {
                throw TractandaError("unresolvedPrincipal", "Unknown fixture account.")
            }
            return .init(uid: uid, name: name, primaryGroupName: "staff", groupIDs: [75091])
        }
        func user(named name: String) throws -> AccountIdentity {
            switch name {
            case "owner": return try user(forUID: tractanda_uid())
            case "alice": return try user(forUID: alice)
            default: throw TractandaError("unresolvedPrincipal", "Unknown fixture account.")
            }
        }
        func groupID(named name: String) throws -> UInt32 {
            guard name == "staff" else {
                throw TractandaError("unresolvedPrincipal", "Unknown fixture group.")
            }
            return 75091
        }
    }
    private func root() throws -> URL {
        try AttachmentFixtureCapacity.requireFree()
        // Estimated current fixtures, including the600KiB body/identity/index copies, stay below16MiB.
        XCTAssertLessThanOrEqual(16 * 1024 * 1024, Int(AttachmentFixtureCapacity.fixtureCapBytes))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "jmap-boundary-" + Identifier.make())
        try PrivateConfiguration.makeDirectory(root)
        return root
    }
    private func makeStore(_ root: URL, _ accounts: Accounts) throws -> ItemStore {
        var limits = PersonalRecoveryIndex.Limits()
        limits.maximumDerivedBytes = AttachmentFixtureCapacity.fixtureCapBytes
        let policy = ItemValue.object([
            "profile": .text(AccessConfiguration.profile),
            "users": .list([.text("owner"), .text("alice")]),
        ])
        return try ItemStore(
            personalRoot: root, opening: .fresh(policy), accounts: accounts,
            attachmentUploadPolicy: .init(minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes),
            recoveryLimits: limits)
    }
    private func initialize(_ root: URL, _ accounts: Accounts) throws { _ = try makeStore(root, accounts) }
    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSON.encode(value)) as? [String: Any])
    }
    private func request(
        _ calls: [[Any]], using: [String] = [JMAPKernel.core, ItemService.capability],
        extra: [String: Any] = [:]
    ) throws -> Data {
        var body: [String: Any] = ["using": using, "methodCalls": calls]
        body.merge(extra) { _, value in value }
        return try JSONSerialization.data(withJSONObject: body)
    }
    private func envelope(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func calls(_ data: Data) throws -> [[Any]] {
        try XCTUnwrap(envelope(data)["methodResponses"] as? [[Any]])
    }
    private func receipt(_ data: Data, method: String = "TractandaItem/commit", id: String = "save") throws
        -> MutationReceipt
    {
        try JSON.decode(MutationReceipt.self, NativeMethodResult.unwrap(data, method: method, callID: id))
    }
    private func assertError(_ data: Data, _ type: String, file: StaticString = #filePath, line: UInt = #line)
        throws
    {
        let call = try XCTUnwrap(calls(data).first, file: file, line: line)
        XCTAssertEqual(call[0] as? String, "error", file: file, line: line)
        XCTAssertEqual((call[1] as? [String: Any])?["type"] as? String, type, file: file, line: line)
    }

    func testCoreOnlyEchoReferencesAndFutureRequestFieldsMatchSyncAndAsyncDrivers() async throws {
        let firstRoot = try root()
        let secondRoot = try root()
        let accounts = Accounts()
        defer {
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: secondRoot)
        }
        let sync = ItemService(store: try makeStore(firstRoot, accounts))
        try initialize(secondRoot, accounts)
        let async = try await ServiceCoordinator(opening: secondRoot, makeAccountDirectory: { accounts })
        let input = try request(
            [
                ["Core/echo", ["list": [["ids": ["a"]], ["ids": ["b", "c"]]]], ""],
                [
                    "Core/echo", ["#mapped": ["resultOf": "", "name": "Core/echo", "path": "/list/*/ids"]],
                    "",
                ],
                ["Unknown/method", [:], "last"], ["Core/echo", ["ok": true], "last"],
            ], using: [JMAPKernel.core], extra: ["future": ["ignored": true]])
        let syncReply = try envelope(sync.handle(input, peerUID: tractanda_uid()))
        let asyncReply = try await envelope(async.handle(input, forUID: tractanda_uid()))
        XCTAssertEqual(syncReply["methodResponses"] as? NSArray, asyncReply["methodResponses"] as? NSArray)
        let replies = try XCTUnwrap(syncReply["methodResponses"] as? [[Any]])
        XCTAssertEqual((replies[1][1] as? [String: Any])?["mapped"] as? [String], ["a", "b", "c"])
        XCTAssertEqual((replies[2][1] as? [String: Any])?["type"] as? String, "unknownMethod")
        XCTAssertNotNil(syncReply["sessionState"] as? String)
        XCTAssertNotNil(asyncReply["sessionState"] as? String)
        await async.close()
    }

    func testRequestRejectionPrecedesAnyItemMutationAndCallerArgumentsCannotImpersonate() throws {
        let root = try root()
        let accounts = Accounts()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root, accounts)
        let service = ItemService(store: store)
        let create = try object(
            CommitRequest(
                classID: "Item", changes: ["subject": .text("must not commit")], operationID: "reject"))
        let unknown = service.handle(
            try request(
                [["TractandaItem/commit", create, "save"]], using: [ItemService.capability, "unknown"]),
            peerUID: accounts.alice)
        XCTAssertEqual(
            try envelope(unknown)["type"] as? String, "urn:ietf:params:jmap:error:unknownCapability")
        let malformed = service.handle(
            try request([
                ["TractandaItem/commit", create, "save"], ["Core/echo", "invalid arguments shape", "bad"],
            ]), peerUID: accounts.alice)
        XCTAssertEqual(try envelope(malformed)["type"] as? String, "urn:ietf:params:jmap:error:notRequest")
        let duplicate = Data(##"{"using":[],"methodCalls":[],"\u006dethodCalls":[]}"##.utf8)
        XCTAssertEqual(
            try envelope(service.handle(duplicate, peerUID: accounts.alice))["type"] as? String,
            "urn:ietf:params:jmap:error:notJSON")
        var spoofed = create
        spoofed["actor"] = "uid:0"
        try assertError(
            service.handle(
                try request([["TractandaItem/commit", spoofed, "save"]]), peerUID: accounts.alice),
            "invalidArguments")
        XCTAssertTrue(try store.candidates().isEmpty)
    }

    func testLargeMutationReturnsCompactReceiptAndSameBatchPinnedRevision() throws {
        let root = try root()
        let accounts = Accounts()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ItemService(store: try makeStore(root, accounts))
        let text = String(repeating: "x", count: 600_000)
        let write = try object(
            CommitRequest(classID: "Item", changes: ["body": .text(text)], operationID: "large-save"))
        let response = service.handle(
            try request([
                ["TractandaItem/commit", write, "save"],
                [
                    "TractandaRevision/get",
                    [
                        "#itemID": ["resultOf": "save", "name": "TractandaItem/commit", "path": "/itemId"],
                        "#revisionID": [
                            "resultOf": "save", "name": "TractandaItem/commit", "path": "/revisionId",
                        ],
                    ], "read",
                ],
            ]), peerUID: tractanda_uid())
        let replies = try calls(response)
        let saved = try XCTUnwrap(replies[0][1] as? [String: Any])
        XCTAssertLessThan(try JSONSerialization.data(withJSONObject: saved).count, 4096)
        XCTAssertNil(saved["revision"])
        XCTAssertNil(saved["requestIdentity"])
        XCTAssertNil(saved["itemState"])
        let pinned = try XCTUnwrap((replies[1][1] as? [String: Any])?["revision"] as? [String: Any])
        let fields = try XCTUnwrap(pinned["fields"] as? [String: Any])
        XCTAssertEqual(
            (fields["revisionID"] as? [String: Any])?["value"] as? String, saved["revisionId"] as? String)
        XCTAssertEqual((fields["body"] as? [String: Any])?["value"] as? String, text)
    }

    func testSessionMetadataStateIsSeparateFromContentState() throws {
        let root = try root()
        let accounts = Accounts()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root, accounts)
        let service = ItemService(store: store)
        let echo = try request([["Core/echo", [:], "echo"]], using: [JMAPKernel.core])
        let before = try envelope(service.handle(echo, peerUID: tractanda_uid()))["sessionState"] as? String
        let contentBefore = store.state
        let input = try object(
            CommitRequest(classID: "Item", changes: ["subject": .text("edit")], operationID: "metadata-save"))
        _ = try receipt(
            service.handle(try request([["TractandaItem/commit", input, "save"]]), peerUID: tractanda_uid()))
        let after = try envelope(service.handle(echo, peerUID: tractanda_uid()))["sessionState"] as? String
        XCTAssertNotNil(before)
        XCTAssertEqual(before, after)
        XCTAssertNotEqual(contentBefore, store.state)
    }

    func testAcknowledgedSaveRemainsSuccessWhenFollowingReadLosesCurrentAccess() throws {
        let root = try root()
        let accounts = Accounts()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root, accounts)
        let service = ItemService(store: store)
        store.beforeIndexUpdate = { accounts.revokeAlice() }
        let input = try object(
            CommitRequest(
                classID: "Item", changes: ["subject": .text("saved")], operationID: "revoke-after-save"))
        let response = service.handle(
            try request([
                ["TractandaItem/commit", input, "save"],
                [
                    "TractandaRevision/get",
                    [
                        "#itemID": ["resultOf": "save", "name": "TractandaItem/commit", "path": "/itemId"],
                        "#revisionID": [
                            "resultOf": "save", "name": "TractandaItem/commit", "path": "/revisionId",
                        ],
                    ], "read",
                ],
            ]), peerUID: accounts.alice)
        let replies = try calls(response)
        XCTAssertEqual(replies[0][0] as? String, "TractandaItem/commit")
        XCTAssertEqual((replies[0][1] as? [String: Any])?["operationId"] as? String, "revoke-after-save")
        XCTAssertEqual(replies[1][0] as? String, "error")
        XCTAssertEqual((replies[1][1] as? [String: Any])?["type"] as? String, "forbidden")
        XCTAssertNotNil(try envelope(response)["sessionState"] as? String)
        store.beforeIndexUpdate = nil
    }

    func testLateStateMismatchAfterPublicationIsPartialAndExactRetryAcknowledges() throws {
        let root = try root()
        let accounts = Accounts()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root, accounts)
        let service = ItemService(store: store)
        store.beforePersonalDurableAcknowledgementForTesting = {
            throw TractandaError("stateMismatch", "injected after publication")
        }
        let input = try object(
            CommitRequest(
                classID: "Item", changes: ["subject": .text("durably published")], operationID: "late-failure"
            ))
        let bytes = try request([["TractandaItem/commit", input, "save"]])
        try assertError(service.handle(bytes, peerUID: tractanda_uid()), "serverPartialFail")
        store.beforePersonalDurableAcknowledgementForTesting = nil
        try store.rebuildIndex()
        let replay = try receipt(service.handle(bytes, peerUID: tractanda_uid()))
        XCTAssertTrue(replay.wasReplayed)
        XCTAssertEqual(replay.operationID, "late-failure")
        XCTAssertEqual(try store.history(replay.itemID).count, 1)
    }

    func testFeedbackPublicationAcknowledgementFailureIsPartialAndKeepsItsOriginalOperationID() throws {
        let root = try root()
        let accounts = Accounts()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root, accounts)
        let service = ItemService(store: store)
        let category = try store.commit(
            .init(
                classID: "Item",
                changes: [
                    "subject": .text("Category"),
                    "selection": .object([
                        "language": .text(SpotlightQuery.profile),
                        "expression": .text("subject == \"never\""),
                    ]),
                ], operationID: "category")
        ).revision
        let target = try store.commit(
            .init(classID: "Item", changes: ["subject": .text("Example")], operationID: "target")
        ).revision
        store.beforePersonalDurableAcknowledgementForTesting = {
            throw TractandaError("stateMismatch", "injected after index commit")
        }
        let input: [String: Any] = [
            "itemID": target.itemID, "categoryID": category.itemID,
            "expectedRevisionID": target.revisionID, "action": "negative", "operationID": "feedback-late",
        ]
        let bytes = try request([["TractandaLearning/feedback", input, "feedback"]])
        try assertError(service.handle(bytes, peerUID: tractanda_uid()), "serverPartialFail")
        store.beforePersonalDurableAcknowledgementForTesting = nil
        try store.rebuildIndex()
        let replay = try receipt(
            service.handle(bytes, peerUID: tractanda_uid()), method: "TractandaLearning/feedback",
            id: "feedback")
        XCTAssertTrue(replay.wasReplayed)
        XCTAssertEqual(replay.operationID, "feedback-late")
        XCTAssertEqual(
            try store.history(target.itemID).filter { $0.fields["operationID"]?.string == "feedback-late" }
                .count, 1)
    }
}
