import Crypto
import TractandaClient
import XCTest

@testable import TractandaCore

final class AttachmentResumableUploadTests: XCTestCase, @unchecked Sendable {
    private actor Gate {
        var arrivals = 0
        var released = false
        func enter() async throws {
            arrivals += 1
            while !released {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        func release() { released = true }
        func awaitArrival() async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while arrivals == 0 {
                guard ContinuousClock.now < deadline else {
                    throw TractandaError("testTimeout", "Integrity gate did not start.")
                }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }
    private struct Transport: ItemTransport {
        let coordinator: ServiceCoordinator
        let uid: UInt32
        func send(_ request: Data) async throws -> Data { try await coordinator.handle(request, forUID: uid) }
    }
    private func root() throws -> URL {
        try AttachmentFixtureCapacity.requireFree()
        return FileManager.default.temporaryDirectory.appendingPathComponent(
            "resumable-upload-" + Identifier.make())
    }
    private func intent(_ revision: Revision, bytes: Data, count: Int64? = nil) -> AttachmentUploadRequest {
        AttachmentUploadRequest(
            itemID: revision.itemID, expectedRevisionID: revision.revisionID,
            operationID: "original", filename: "large.pdf", mediaType: "application/pdf",
            byteCount: count ?? Int64(bytes.count),
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }
    private func create(_ store: ItemStore) throws -> Revision {
        try store.commit(CommitRequest(classID: "Item", operationID: "item")).revision
    }
    private func request(_ method: String, _ arguments: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "using": [ItemService.capability], "methodCalls": [[method, arguments, "test"]],
        ])
    }
    private func payload(_ data: Data) throws -> [String: Any] {
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let calls = try XCTUnwrap(envelope["methodResponses"] as? [[Any]])
        return try XCTUnwrap(calls.first?[1] as? [String: Any])
    }
    func testSlidingIdleRetentionAndLostChunkReplySurviveRestart() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        var store: ItemStore? = try ItemStore(root: directory)
        let base = try create(XCTUnwrap(store))
        let bytes = Data("sixsix".utf8)
        let operation = intent(base, bytes: bytes)
        let start = Date()
        store?.attachmentClockForTesting = { start }
        let upload = try XCTUnwrap(store).beginAttachment(operation)
        let id = try XCTUnwrap(upload.uploadID)
        store?.attachmentClockForTesting = { start.addingTimeInterval(3500) }
        _ = try XCTUnwrap(store).appendAttachment(uploadID: id, offset: 0, data: bytes.prefix(3))
        store?.attachmentClockForTesting = { start.addingTimeInterval(7000) }
        let resumed = try XCTUnwrap(store).beginAttachment(operation)
        XCTAssertEqual(resumed.uploadID, id)
        XCTAssertEqual(resumed.offset, 3)
        // Lost acknowledgement: the identical chunk is accepted and renews idle retention.
        _ = try XCTUnwrap(store).appendAttachment(uploadID: id, offset: 0, data: bytes.prefix(3))
        store = nil
        store = try ItemStore(root: directory)
        store?.attachmentClockForTesting = { start.addingTimeInterval(10500) }
        let restarted = try XCTUnwrap(store).beginAttachment(operation)
        XCTAssertEqual(restarted.uploadID, id)
        XCTAssertEqual(restarted.offset, 3)
        _ = try XCTUnwrap(store).appendAttachment(uploadID: id, offset: 3, data: bytes.suffix(3))
        let committed = try XCTUnwrap(store).finishAttachment(uploadID: id)
        store = nil
        store = try ItemStore(root: directory)
        XCTAssertEqual(
            try XCTUnwrap(store).beginAttachment(operation).committed?.revisionID,
            committed.revision.revisionID)
        XCTAssertEqual(
            try XCTUnwrap(store).attachmentContent(
                itemID: base.itemID, attachmentID: upload.attachment.attachmentID
            ).data, bytes)
    }
    func testAddressableMetadataAndActualByteQuotaUseNoLargeFixture() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(
            root: directory, attachmentUploadPolicy: AttachmentUploadPolicy(maximumStagedBytes: 20 * 1024))
        store.attachmentClockForTesting = { Date(timeIntervalSince1970: 1_700_000_000) }
        let base = try create(store)
        let request = intent(base, bytes: Data("unused".utf8), count: .max)
        let service = ItemService(store: store)
        let client = TractandaCore.ItemClient(transport: { service.handle($0, peerUID: getuid()) })
        let upload = try client.beginAttachment(request)
        XCTAssertEqual(upload.attachment.byteCount, .max)
        let id = try XCTUnwrap(upload.uploadID)
        let checkpoint = try FileMetadata.read(
            at: directory.appendingPathComponent("attachments/.uploads/" + id + ".json")
        ).size
        let amount = 20 * 1024 - 16 * 1024 - Int(checkpoint)
        XCTAssertGreaterThan(amount, 0)
        XCTAssertEqual(
            try client.appendAttachment(uploadID: id, offset: 0, data: Data(repeating: 1, count: amount)),
            Int64(amount))
        XCTAssertThrowsError(
            try client.appendAttachment(uploadID: id, offset: Int64(amount), data: Data([5]))
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
        }
        XCTAssertThrowsError(try client.appendAttachment(uploadID: id, offset: .max, data: Data([5]))) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "invalidArguments")
        }
        XCTAssertEqual(
            try FileMetadata.read(
                at: directory.appendingPathComponent("attachments/.staging/" + id + ".stage")
            ).size, UInt64(amount))
    }
    func testHashTaskJoinsDoesNotBlockQueriesAndRestartsAfterControlledCancellation() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data("tiny original".utf8)
        let upload: AttachmentUploadResult
        let operation: AttachmentUploadRequest
        do {
            let store = try ItemStore(root: directory)
            operation = intent(try create(store), bytes: bytes)
            upload = try store.beginAttachment(operation)
            _ = try store.appendAttachment(uploadID: XCTUnwrap(upload.uploadID), offset: 0, data: bytes)
        }
        let id = try XCTUnwrap(upload.uploadID)
        let finish = try request("TractandaAttachment/finish", ["uploadID": id])
        let coordinator = try await ServiceCoordinator(opening: directory)
        let gate = Gate()
        await coordinator.setAttachmentIntegrityHookForTesting { try await gate.enter() }
        let first = try payload(await coordinator.handle(finish, forUID: getuid()))
        XCTAssertEqual(first["type"] as? String, "attachmentVerifying")
        XCTAssertEqual(first["retryable"] as? Bool, true)
        XCTAssertEqual(first["totalBytes"] as? Int, bytes.count)
        try await gate.awaitArrival()
        let repeated = try payload(await coordinator.handle(finish, forUID: getuid()))
        XCTAssertEqual(repeated["type"] as? String, "attachmentVerifying")
        let arrivals = await gate.arrivals
        XCTAssertEqual(arrivals, 1)
        let info = try request("TractandaStore/info", [:])
        let response = try await coordinator.handle(info, forUID: getuid())
        XCTAssertNotNil(try payload(response)["features"])
        await coordinator.close()
        let restarted = try await ServiceCoordinator(opening: directory)
        let client = TractandaClient.ItemClient(transport: Transport(coordinator: restarted, uid: getuid()))
        let status = try await client.attachmentUploadStatus(uploadID: id)
        XCTAssertEqual(status.phase, "paused")
        let committed = try await client.finishAttachment(uploadID: id)
        XCTAssertEqual(committed.itemID, operation.itemID)
        let replay = try await client.beginAttachment(operation)
        XCTAssertEqual(replay.committed?.revisionID, committed.revisionID)
        let content = try await client.attachmentContent(
            itemID: committed.itemID, attachmentID: upload.attachment.attachmentID)
        XCTAssertEqual(content.data, bytes)
        await restarted.close()
    }
    func testSingletonRestrictionPreventsBlockingFallbackWhileMetadataBatchesWork() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = try await ServiceCoordinator(opening: directory)
        let batch = try JSONSerialization.data(withJSONObject: [
            "using": [ItemService.capability],
            "methodCalls": [
                [
                    "TractandaAttachment/content",
                    ["itemID": Identifier.make(), "attachmentID": Identifier.make()], "one",
                ],
                ["TractandaStore/info", [:], "two"],
            ],
        ])
        let response = try await coordinator.handle(batch, forUID: getuid())
        XCTAssertEqual(try payload(response)["type"] as? String, "attachmentSingletonRequired")
        let metadata = try JSONSerialization.data(withJSONObject: [
            "using": [ItemService.capability],
            "methodCalls": [
                ["TractandaStore/info", [:], "one"], ["TractandaStore/info", [:], "two"],
            ],
        ])
        let normal = try await coordinator.handle(metadata, forUID: getuid())
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: normal) as? [String: Any])
        XCTAssertEqual((envelope["methodResponses"] as? [[Any]])?.count, 2)
        await coordinator.close()
    }
    private final class Accounts: AccountDirectory, @unchecked Sendable {
        let alice: UInt32 = 61991
        private let lock = NSLock()
        private var admitted = true
        func revoke() {
            lock.lock()
            admitted = false
            lock.unlock()
        }
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            guard uid == getuid() || uid == alice else {
                throw TractandaError("unresolvedPrincipal", "Unknown fixture user")
            }
            lock.lock()
            let groups: Set<UInt32> = uid == getuid() || admitted ? [71991] : []
            lock.unlock()
            return AccountIdentity(
                uid: uid, name: uid == alice ? "alice" : "admin", primaryGroupName: "staff", groupIDs: groups)
        }
        func user(named name: String) throws -> AccountIdentity {
            guard name == "admin" || name == "alice" else {
                throw TractandaError("unresolvedPrincipal", "Unknown fixture user")
            }
            return try user(forUID: name == "alice" ? alice : getuid())
        }
        func groupID(named name: String) throws -> UInt32 {
            guard name == "staff" else {
                throw TractandaError("unresolvedPrincipal", "Unknown fixture group")
            }
            return 71991
        }
    }
    func testPermissionRevocationHidesStatusAndPreventsPublicationAfterBackgroundHash() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let accounts = Accounts()
        let upload: AttachmentUploadResult
        do {
            let store = try ItemStore(root: directory, accounts: accounts)
            _ = try store.configureAccess(
                .object(["profile": .text(AccessConfiguration.profile), "groups": .list([.text("staff")])]),
                operationID: "access")
            let revision = try store.commit(
                CommitRequest(
                    classID: "Item",
                    changes: [
                        "permissions": .object([
                            "profile": .text(ItemPermissions.profile), "owner": .text("admin"),
                            "group": .text("staff"), "mode": .integer(0o660), "acl": .object([:]),
                        ])
                    ], operationID: "item")
            ).revision
            let bytes = Data("tiny private original".utf8)
            upload = try store.withAccess(forUID: accounts.alice) {
                let result = try store.beginAttachment(intent(revision, bytes: bytes))
                _ = try store.appendAttachment(uploadID: XCTUnwrap(result.uploadID), offset: 0, data: bytes)
                return result
            }
        }
        let coordinator = try await ServiceCoordinator(opening: directory, makeAccountDirectory: { accounts })
        let gate = Gate()
        await coordinator.setAttachmentIntegrityHookForTesting { try await gate.enter() }
        let id = try XCTUnwrap(upload.uploadID)
        let finish = try request("TractandaAttachment/finish", ["uploadID": id])
        let pending = try await coordinator.handle(finish, forUID: accounts.alice)
        XCTAssertEqual(try payload(pending)["type"] as? String, "attachmentVerifying")
        try await gate.awaitArrival()
        accounts.revoke()
        let statusRequest = try request("TractandaAttachment/uploadStatus", ["uploadID": id])
        let denied = try await coordinator.handle(statusRequest, forUID: accounts.alice)
        let error = try JSON.decode(TractandaError.self, denied)
        XCTAssertEqual(error.code, "forbidden")
        XCTAssertFalse(String(decoding: denied, as: UTF8.self).contains(upload.attachment.sha256))
        await gate.release()
        let finishDenied = try await coordinator.handle(finish, forUID: accounts.alice)
        XCTAssertEqual(try JSON.decode(TractandaError.self, finishDenied).code, "forbidden")
        await coordinator.close()
        let storage = try AttachmentPayloadStore(root: directory, ownerUID: getuid())
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: try storage.payloadURL(for: upload.attachment.attachmentID).path))
    }
    func testColdOriginalReadSharesHashTaskAndRechecksHistoricalPermission() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data("cold original".utf8)
        let descriptor: AttachmentDescriptor
        let itemID: String
        let revisionID: String
        do {
            let store = try ItemStore(root: directory)
            let revision = try create(store)
            let upload = try store.beginAttachment(intent(revision, bytes: bytes))
            descriptor = upload.attachment
            _ = try store.appendAttachment(uploadID: XCTUnwrap(upload.uploadID), offset: 0, data: bytes)
            let committed = try store.finishAttachment(uploadID: XCTUnwrap(upload.uploadID))
            itemID = revision.itemID
            revisionID = committed.revision.revisionID
        }
        let coordinator = try await ServiceCoordinator(opening: directory)
        let gate = Gate()
        await coordinator.setAttachmentIntegrityHookForTesting { try await gate.enter() }
        let read = try request(
            "TractandaAttachment/content",
            [
                "itemID": itemID, "revisionID": revisionID, "attachmentID": descriptor.attachmentID,
                "offset": 0, "limit": 3,
            ])
        let pending = try await coordinator.handle(read, forUID: getuid())
        XCTAssertEqual(try payload(pending)["type"] as? String, "attachmentVerifying")
        try await gate.awaitArrival()
        _ = try await coordinator.handle(read, forUID: getuid())
        let count = await gate.arrivals
        XCTAssertEqual(count, 1)
        await gate.release()
        let client = TractandaClient.ItemClient(transport: Transport(coordinator: coordinator, uid: getuid()))
        let content = try await client.attachmentContent(
            itemID: itemID, revisionID: revisionID, attachmentID: descriptor.attachmentID, limit: 3)
        XCTAssertEqual(content.data, bytes.prefix(3))
        let status = try await client.attachmentIntegrityStatus(
            itemID: itemID, revisionID: revisionID, attachmentID: descriptor.attachmentID)
        XCTAssertEqual(status.verifiedBytes, Int64(bytes.count))
        XCTAssertEqual(status.phase, "verified")
        await coordinator.close()
    }

    func testFailedIntegrityIsTerminalInsteadOfAnEndlessPendingRetry() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id: String
        do {
            let store = try ItemStore(root: directory)
            let revision = try create(store)
            let bad = AttachmentUploadRequest(
                itemID: revision.itemID, expectedRevisionID: revision.revisionID, operationID: "bad",
                filename: "bad.pdf", mediaType: "application/pdf", byteCount: 1,
                sha256: String(repeating: "0", count: 64))
            let upload = try store.beginAttachment(bad)
            id = try XCTUnwrap(upload.uploadID)
            _ = try store.appendAttachment(uploadID: id, offset: 0, data: Data([1]))
        }
        let coordinator = try await ServiceCoordinator(opening: directory)
        let finish = try request("TractandaAttachment/finish", ["uploadID": id])
        let pending = try await coordinator.handle(finish, forUID: getuid())
        XCTAssertEqual(try payload(pending)["type"] as? String, "attachmentVerifying")
        let client = TractandaClient.ItemClient(transport: Transport(coordinator: coordinator, uid: getuid()))
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while try await client.attachmentUploadStatus(uploadID: id).phase != "failed" {
            guard ContinuousClock.now < deadline else {
                throw TractandaError("testTimeout", "Checksum failure did not become terminal.")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        do {
            _ = try await client.finishAttachment(uploadID: id)
            XCTFail("Checksum mismatch must fail")
        } catch let error as TractandaError { XCTAssertEqual(error.code, "attachmentIntegrity") }
        await coordinator.close()
    }
    func testTemporaryCopyGuardPreservesCommittedReplayAndLegacyNetworkRejectsHeavyCalls() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory)
        let revision = try create(store)
        let bytes = Data("copy".utf8)
        let upload = try store.beginAttachment(intent(revision, bytes: bytes))
        _ = try store.appendAttachment(uploadID: XCTUnwrap(upload.uploadID), offset: 0, data: bytes)
        let attached = try store.finishAttachment(uploadID: XCTUnwrap(upload.uploadID)).revision
        let originalCopy = CommitRequest(
            action: .copy, itemID: attached.itemID, expectedRevisionID: attached.revisionID,
            operationID: "copy")
        let copied = try store.commit(originalCopy)
        XCTAssertEqual(
            try store.commit(originalCopy, allowBlockingAttachmentCopy: false).revision.revisionID,
            copied.revision.revisionID)
        XCTAssertThrowsError(
            try store.commit(
                CommitRequest(
                    action: .copy, itemID: attached.itemID, expectedRevisionID: attached.revisionID,
                    operationID: "new-copy"), allowBlockingAttachmentCopy: false)
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "attachmentCopyRequiresJob")
        }
        let service = ItemService(store: store)
        service.rejectsBlockingNetworkAttachments = true
        for method in ["TractandaAttachment/finish", "TractandaAttachment/content"] {
            let response = service.handle(try request(method, [:]), peerUID: getuid())
            XCTAssertEqual(try payload(response)["type"] as? String, "attachmentRequiresDaemon")
        }
        let info = try payload(service.handle(request("TractandaStore/info", [:]), peerUID: getuid()))
        XCTAssertFalse(
            (info["features"] as? [String] ?? []).contains(ServerFeature.resumableAttachmentTransfer.rawValue)
        )
    }

    func testCleanupTombstoneRecoversAbortAndExpiryCrashWindows() throws {
        for cleanup in ["abort", "expiry"] {
            let directory = try root()
            defer { try? FileManager.default.removeItem(at: directory) }
            var store: ItemStore? = try ItemStore(root: directory)
            let bytes = Data("partial".utf8)
            let operation = intent(try create(XCTUnwrap(store)), bytes: bytes)
            let upload = try XCTUnwrap(store).beginAttachment(operation)
            let id = try XCTUnwrap(upload.uploadID)
            _ = try XCTUnwrap(store).appendAttachment(uploadID: id, offset: 0, data: bytes.prefix(1))
            store?.afterAttachmentStageDiscardForTesting = {
                throw TractandaError("injected", "After durable stage unlink")
            }
            if cleanup == "expiry" {
                store?.attachmentClockForTesting = { Date().addingTimeInterval(3601) }
                XCTAssertThrowsError(try XCTUnwrap(store).beginAttachment(operation))
            } else {
                XCTAssertThrowsError(try XCTUnwrap(store).abortAttachment(uploadID: id))
            }
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent("attachments/.staging/" + id + ".stage").path))
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent("attachments/.uploads/" + id + ".json").path))
            store = nil
            store = try ItemStore(root: directory)
            let resumed = try XCTUnwrap(store).beginAttachment(operation)
            XCTAssertNotEqual(resumed.uploadID, id)
            XCTAssertEqual(resumed.offset, 0)
            XCTAssertEqual(
                try XCTUnwrap(store).get(operation.itemID).revisionID, operation.expectedRevisionID)
        }
    }
    func testColdPublishedIntegrityKeepsLocationForResumeAndOtherUploadQuota() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data("published before CAS".utf8)
        let operation: AttachmentUploadRequest
        let id: String
        let otherID: String
        do {
            let store = try ItemStore(root: directory)
            let revision = try create(store)
            operation = intent(revision, bytes: bytes)
            let upload = try store.beginAttachment(operation)
            id = try XCTUnwrap(upload.uploadID)
            _ = try store.appendAttachment(uploadID: id, offset: 0, data: bytes)
            store.beforeAttachmentCommitForTesting = {
                throw TractandaError("injected", "After payload publication")
            }
            XCTAssertThrowsError(try store.finishAttachment(uploadID: id))
            let other = AttachmentUploadRequest(
                itemID: revision.itemID, expectedRevisionID: revision.revisionID, operationID: "other",
                filename: "other.pdf", mediaType: "application/pdf", byteCount: 1,
                sha256: SHA256.hash(data: Data([7])).map { String(format: "%02x", $0) }.joined())
            otherID = try XCTUnwrap(store.beginAttachment(other).uploadID)
        }
        let coordinator = try await ServiceCoordinator(opening: directory)
        let client = TractandaClient.ItemClient(transport: Transport(coordinator: coordinator, uid: getuid()))
        let finish = try request("TractandaAttachment/finish", ["uploadID": id])
        let pending = try await coordinator.handle(finish, forUID: getuid())
        XCTAssertEqual(try payload(pending)["type"] as? String, "attachmentVerifying")
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while try await client.attachmentUploadStatus(uploadID: id).phase != "verified" {
            guard ContinuousClock.now < deadline else {
                throw TractandaError("testTimeout", "Cold published hash did not complete")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let resumed = try await client.beginAttachment(operation)
        XCTAssertEqual(resumed.uploadID, id)
        XCTAssertEqual(resumed.offset, Int64(bytes.count))
        let appended = try await client.appendAttachment(uploadID: otherID, offset: 0, data: Data([7]))
        XCTAssertEqual(appended, 1)
        let committed = try await client.finishAttachment(uploadID: id)
        XCTAssertEqual(committed.itemID, operation.itemID)
        await coordinator.close()
    }

    func testPublishedOriginalRecoversBeforeLocationCheckpointIsWritten() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let operation: AttachmentUploadRequest
        let id: String
        do {
            let store = try ItemStore(root: directory)
            let bytes = Data("tiny publication gap".utf8)
            operation = intent(try create(store), bytes: bytes)
            let upload = try store.beginAttachment(operation)
            id = try XCTUnwrap(upload.uploadID)
            _ = try store.appendAttachment(uploadID: id, offset: 0, data: bytes)
            store.afterAttachmentPayloadPublicationForTesting = {
                throw TractandaError(
                    "injected", "After durable payload publication, before location checkpoint")
            }
            XCTAssertThrowsError(try store.finishAttachment(uploadID: id))
            let record = try JSON.decode(
                AttachmentUploadState.self,
                Data(contentsOf: directory.appendingPathComponent("attachments/.uploads/" + id + ".json")))
            XCTAssertEqual(record.location, "staged")
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent("attachments/.staging/" + id + ".stage").path))
        }
        let coordinator = try await ServiceCoordinator(opening: directory)
        let client = TractandaClient.ItemClient(transport: Transport(coordinator: coordinator, uid: getuid()))
        let resumed = try await client.beginAttachment(operation)
        XCTAssertEqual(resumed.uploadID, id)
        XCTAssertEqual(resumed.offset, operation.byteCount)
        let committed = try await client.finishAttachment(uploadID: id)
        XCTAssertEqual(committed.itemID, operation.itemID)
        await coordinator.close()
    }

}
