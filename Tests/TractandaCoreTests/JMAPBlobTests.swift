import Crypto
import TractandaClient
import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class JMAPBlobTests: XCTestCase {
    override func setUpWithError() throws { try AttachmentFixtureCapacity.requireFree() }
    private func fixture() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("jmap-blob-" + Identifier.make())
    }
    private func limits(size: Int64 = 16 * 1024 * 1024, quota: Int64 = 32 * 1024 * 1024) throws
        -> JMAPBlobLimits
    {
        try .init(
            maxSizeUpload: size, maximumStagedBytesPerUser: quota,
            minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes)
    }
    private func code(
        _ value: String, _ body: () throws -> Any, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(($0 as? TractandaError)?.code, value, "\($0)", file: file, line: line)
        }
    }
    private func upload(
        _ store: ItemStore, account: String, bytes: Data, type: String = "application/octet-stream"
    ) throws -> JMAPBlobReceipt {
        let handle = try store.beginBlobUpload(accountID: account, mediaType: type, limits: limits())
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + 262_144, bytes.count)
            _ = try store.appendBlobUpload(
                uploadID: handle.uploadID, offset: Int64(offset), data: bytes.subdata(in: offset..<end))
            offset = end
        }
        return try store.finishBlobUpload(uploadID: handle.uploadID)
    }
    func testUnknownLengthChunkedBodyDigestBoundedPinnedReadAndRangeBoundaries() throws {
        let root = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AttachmentFixtureCapacity.makeStore(root: root)
        try store.withAccess(forUID: getuid()) {
            let account = try store.nativeProtocolSessionBasis.identity
            let bytes = Data((0..<524_301).map { UInt8($0 % 251) })
            let receipt = try upload(store, account: account, bytes: bytes)
            XCTAssertEqual(receipt.size, Int64(bytes.count))
            XCTAssertEqual(
                receipt.blobId, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
            let handle = try store.beginBlobDownload(accountID: account, blobID: receipt.blobId)
            defer { try? store.closeBlobDownload(downloadID: handle.downloadID) }
            code("attachmentVerifying") { try handle.source.read(offset: 0, limit: 1) }
            try handle.source.verify()
            try store.authorizeBlobDownload(downloadID: handle.downloadID)
            XCTAssertEqual(
                try handle.source.read(offset: 262_144, limit: 262_144), bytes.subdata(in: 262_144..<524_288))
            XCTAssertEqual(try handle.source.read(offset: receipt.size, limit: 262_144), Data())
            code("invalidArguments") { try handle.source.read(offset: -1, limit: 1) }
            code("invalidArguments") { try handle.source.read(offset: 0, limit: 262_145) }
            code("invalidArguments") { try handle.source.read(offset: receipt.size + 1, limit: 0) }
        }
    }
    func testLargeDeclaredBodySmallFixtureIncompleteNeverCompletesAndCancelDisposes() throws {
        let root = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AttachmentFixtureCapacity.makeStore(root: root)
        try store.withAccess(forUID: getuid()) {
            let account = try store.nativeProtocolSessionBasis.identity
            let handle = try store.beginBlobUpload(
                accountID: account, mediaType: "text/plain", declaredSize: 1024 * 1024 * 1024,
                limits: limits(size: 2 * 1024 * 1024 * 1024))
            _ = try store.appendBlobUpload(uploadID: handle.uploadID, offset: 0, data: Data("partial".utf8))
            code("uploadMismatch") { try store.finishBlobUpload(uploadID: handle.uploadID) }
            code("notFound") { try store.finishBlobUpload(uploadID: handle.uploadID) }
            let cancel = try store.beginBlobUpload(
                accountID: account, mediaType: "text/plain", limits: limits())
            _ = try store.appendBlobUpload(
                uploadID: cancel.uploadID, offset: 0, data: Data("disconnect".utf8))
            try store.cancelBlobUpload(uploadID: cancel.uploadID)
            code("notFound") { try store.finishBlobUpload(uploadID: cancel.uploadID) }
        }
    }
    func testLimitsOffsetsInt53AndUnsafeTypeRejectedWithoutLargeAllocation() throws {
        XCTAssertThrowsError(try limits(size: 9_007_199_254_740_992))
        let root = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AttachmentFixtureCapacity.makeStore(root: root)
        try store.withAccess(forUID: getuid()) {
            let account = try store.nativeProtocolSessionBasis.identity
            code("resourceLimit") {
                try store.beginBlobUpload(
                    accountID: account, mediaType: "text/plain", declaredSize: 101, limits: limits(size: 100))
            }
            code("invalidArguments") {
                try store.beginBlobUpload(
                    accountID: account, mediaType: "text/plain\r\nX-Evil: 1", limits: limits())
            }
            let handle = try store.beginBlobUpload(
                accountID: account, mediaType: "text/plain", limits: limits(size: 4))
            code("invalidArguments") {
                try store.appendBlobUpload(uploadID: handle.uploadID, offset: 1, data: Data([1]))
            }
            code("invalidArguments") {
                try store.appendBlobUpload(
                    uploadID: handle.uploadID, offset: 0, data: Data(repeating: 1, count: 262_145))
            }
            _ = try store.appendBlobUpload(uploadID: handle.uploadID, offset: 0, data: Data([1, 2, 3, 4]))
            code("invalidArguments") {
                try store.appendBlobUpload(uploadID: handle.uploadID, offset: 4, data: Data([5]))
            }
            XCTAssertEqual(try store.finishBlobUpload(uploadID: handle.uploadID).size, 4)
        }
    }
    func testCompletedReceiptRestartsAndIncompleteStartupIsDiscarded() throws {
        let root = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt: JMAPBlobReceipt
        let incompleteID: String
        do {
            let store = try AttachmentFixtureCapacity.makeStore(root: root)
            (receipt, incompleteID) = try store.withAccess(forUID: getuid()) {
                let account = try store.nativeProtocolSessionBasis.identity
                let done = try upload(store, account: account, bytes: Data("durable".utf8))
                let handle = try store.beginBlobUpload(
                    accountID: account, mediaType: "text/plain", limits: limits())
                _ = try store.appendBlobUpload(
                    uploadID: handle.uploadID, offset: 0, data: Data("incomplete".utf8))
                return (done, handle.uploadID)
            }
        }
        let reopened = try AttachmentFixtureCapacity.makeStore(root: root)
        try reopened.withAccess(forUID: getuid()) {
            let handle = try reopened.beginBlobDownload(accountID: receipt.accountId, blobID: receipt.blobId)
            defer { try? reopened.closeBlobDownload(downloadID: handle.downloadID) }
            try handle.source.verify()
            XCTAssertEqual(try handle.source.read(offset: 0), Data("durable".utf8))
            code("notFound") { try reopened.finishBlobUpload(uploadID: incompleteID) }
        }
    }
    func testActiveUploadHasNoAbsoluteTimeoutAndCompletedMinimumRetention() throws {
        let root = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AttachmentFixtureCapacity.makeStore(root: root)
        try store.withAccess(forUID: getuid()) {
            let account = try store.nativeProtocolSessionBasis.identity
            let handle = try store.beginBlobUpload(
                accountID: account, mediaType: "text/plain", limits: limits())
            try store.expireJMAPBlobsForTesting(now: Date().addingTimeInterval(86_400))
            _ = try store.appendBlobUpload(uploadID: handle.uploadID, offset: 0, data: Data([7]))
            let receipt = try store.finishBlobUpload(uploadID: handle.uploadID)
            let beforeExpiry = try store.beginBlobDownload(accountID: account, blobID: receipt.blobId)
            try store.closeBlobDownload(downloadID: beforeExpiry.downloadID)
            try store.expireJMAPBlobsForTesting(now: Date().addingTimeInterval(86_400 + 3599))
            let retained = try store.beginBlobDownload(accountID: account, blobID: receipt.blobId)
            try store.closeBlobDownload(downloadID: retained.downloadID)
            try store.expireJMAPBlobsForTesting(now: Date().addingTimeInterval(86_400 + 3601))
            code("notFound") { try store.beginBlobDownload(accountID: account, blobID: receipt.blobId) }
        }
    }
    func testQuotaEvictsOldestCompletedStageAndNeverActiveStage() throws {
        let root = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AttachmentFixtureCapacity.makeStore(root: root)
        try store.withAccess(forUID: getuid()) {
            let account = try store.nativeProtocolSessionBasis.identity
            let small = try limits(size: 1024, quota: 20_000)
            let first = try store.beginBlobUpload(accountID: account, mediaType: "text/plain", limits: small)
            _ = try store.appendBlobUpload(uploadID: first.uploadID, offset: 0, data: Data([1]))
            let old = try store.finishBlobUpload(uploadID: first.uploadID)
            let active = try store.beginBlobUpload(accountID: account, mediaType: "text/plain", limits: small)
            let third = try store.beginBlobUpload(accountID: account, mediaType: "text/plain", limits: small)
            _ = try store.appendBlobUpload(uploadID: active.uploadID, offset: 0, data: Data([2]))
            code("notFound") { try store.beginBlobDownload(accountID: account, blobID: old.blobId) }
            _ = try store.finishBlobUpload(uploadID: active.uploadID)
            try store.cancelBlobUpload(uploadID: third.uploadID)
        }
    }
    func testAttachReplayAfterStageExpiryAndDisposableIndexRebuild() throws {
        let root = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let intent: JMAPAttachBlobRequest
        let committed: String
        do {
            let store = try AttachmentFixtureCapacity.makeStore(root: root)
            (intent, committed) = try store.withAccess(forUID: getuid()) {
                let account = try store.nativeProtocolSessionBasis.identity
                let base = try store.commit(.init(classID: "Item", operationID: "base")).revision
                let bytes = Data("attach exact bytes".utf8)
                let blob = try upload(store, account: account, bytes: bytes)
                let request = JMAPAttachBlobRequest(
                    accountID: account, itemID: base.itemID, expectedRevisionID: base.revisionID,
                    blobID: blob.blobId, filename: "note.txt", mediaType: "text/plain",
                    operationID: "exact-attach")
                let prepared = try store.prepareBlobAttachment(request)
                let id = try XCTUnwrap(prepared.uploadID)
                _ = try store.appendAttachment(uploadID: id, offset: 0, data: bytes)
                let result = try store.finishAttachment(uploadID: id)
                try store.expireJMAPBlobsForTesting(now: Date().addingTimeInterval(3601))
                XCTAssertTrue(try XCTUnwrap(store.prepareBlobAttachment(request).committed).wasReplayed)
                return (request, result.revision.revisionID)
            }
        }
        // Rebuild disposable metadata only; canonical revisions and owned payload bytes are untouched.
        let index = root.appendingPathComponent("index")
        if FileManager.default.fileExists(atPath: index.path) {
            try FileManager.default.removeItem(at: index)
        }
        let reopened = try AttachmentFixtureCapacity.makeStore(root: root)
        try reopened.withAccess(forUID: getuid()) {
            let replay = try XCTUnwrap(reopened.prepareBlobAttachment(intent).committed)
            XCTAssertEqual(replay.revisionID, committed)
            XCTAssertTrue(replay.wasReplayed)
            let source = try reopened.beginBlobDownload(accountID: intent.accountID, blobID: intent.blobID)
            try source.source.verify()
            XCTAssertEqual(try source.source.read(offset: 0), Data("attach exact bytes".utf8))
            try reopened.closeBlobDownload(downloadID: source.downloadID)
            let changed = JMAPAttachBlobRequest(
                accountID: intent.accountID, itemID: intent.itemID,
                expectedRevisionID: intent.expectedRevisionID,
                blobID: intent.blobID, filename: "different.txt", mediaType: intent.mediaType,
                operationID: intent.operationID)
            code("operationMismatch") { try reopened.prepareBlobAttachment(changed) }
        }
    }
    func testSameAccountCopyUnknownAccountsOpaqueIDsAndPrivateUpload() throws {
        let root = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AttachmentFixtureCapacity.makeStore(root: root)
        try store.withAccess(forUID: getuid()) {
            let account = try store.nativeProtocolSessionBasis.identity
            let receipt = try upload(store, account: account, bytes: Data([9]))
            XCTAssertEqual(
                try store.copyBlob(accountID: account, fromAccountID: account, blobID: receipt.blobId),
                receipt)
            code("accountNotFound") {
                try store.copyBlob(accountID: "unknown", fromAccountID: account, blobID: receipt.blobId)
            }
            code("fromAccountNotFound") {
                try store.copyBlob(accountID: account, fromAccountID: "unknown", blobID: receipt.blobId)
            }
            code("notFound") { try store.beginBlobDownload(accountID: account, blobID: "opaque-valid-id") }
            code("notFound") {
                try store.beginBlobDownload(accountID: account, blobID: String(repeating: "a", count: 64))
            }
        }
    }
    private final class Accounts: AccountDirectory {
        let alice: UInt32 = 50001
        let bob: UInt32 = 50002
        var aliceName = "alice"
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            let name: String
            switch uid {
            case getuid(): name = "admin"
            case alice: name = aliceName
            case bob: name = "bob"
            default: throw TractandaError("unresolvedPrincipal", "Unknown user")
            }
            return .init(uid: uid, name: name, primaryGroupName: "staff", groupIDs: [70001])
        }
        func user(named name: String) throws -> AccountIdentity {
            for uid in [getuid(), alice, bob] {
                let identity = try user(forUID: uid)
                if identity.name == name { return identity }
            }
            throw TractandaError("unresolvedPrincipal", "Unknown user")
        }
        func groupID(named name: String) throws -> UInt32 {
            guard name == "staff" else { throw TractandaError("unresolvedPrincipal", "Unknown group") }
            return 70001
        }
    }
    private func permissions(mode: Int64) -> ItemValue {
        .object([
            "profile": .text(ItemPermissions.profile), "owner": .text("alice"),
            "group": .text("staff"), "mode": .integer(mode), "acl": .object([:]),
        ])
    }
    func testPrivateUploaderScopeUIDReuseAndCurrentACLHistoryRevocation() throws {
        let root = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = Accounts()
        let store = try AttachmentFixtureCapacity.makeStore(root: root, accounts: accounts)
        _ = try store.configureAccess(
            .object([
                "profile": .text(AccessConfiguration.profile),
                "users": .list([.text("alice"), .text("bob")]),
            ]), operationID: "access")
        let (account, receipt, base): (String, JMAPBlobReceipt, Revision) = try store.withAccess(
            forUID: accounts.alice
        ) {
            let account = try store.nativeProtocolSessionBasis.identity
            let receipt = try upload(store, account: account, bytes: Data("private bytes".utf8))
            let base = try store.commit(
                .init(
                    classID: "Item", changes: ["permissions": permissions(mode: 0o640)], operationID: "item")
            ).revision
            return (account, receipt, base)
        }
        try store.withAccess(forUID: accounts.bob) {
            code("notFound") { try store.beginBlobDownload(accountID: account, blobID: receipt.blobId) }
            code("notFound") {
                try store.copyBlob(accountID: account, fromAccountID: account, blobID: receipt.blobId)
            }
        }
        let attached = try store.withAccess(forUID: accounts.alice) {
            let prepared = try store.prepareBlobAttachment(
                .init(
                    accountID: account, itemID: base.itemID,
                    expectedRevisionID: base.revisionID, blobID: receipt.blobId, filename: "private.txt",
                    mediaType: "text/plain", operationID: "attach"))
            let id = try XCTUnwrap(prepared.uploadID)
            _ = try store.appendAttachment(uploadID: id, offset: 0, data: Data("private bytes".utf8))
            return try store.finishAttachment(uploadID: id).revision
        }
        let privateReceipt = try store.withAccess(forUID: accounts.alice) {
            try upload(store, account: account, bytes: Data("uploader only".utf8))
        }
        let handle = try store.withAccess(forUID: accounts.bob) {
            try store.beginBlobDownload(accountID: account, blobID: receipt.blobId)
        }
        try handle.source.verify()
        _ = try store.commit(
            .init(
                action: .revise, itemID: base.itemID, expectedRevisionID: attached.revisionID,
                changes: ["permissions": permissions(mode: 0o600)], operationID: "revoke"))
        try store.withAccess(forUID: accounts.bob) {
            code("forbidden") { try store.authorizeBlobDownload(downloadID: handle.downloadID) }
            code("notFound") { try store.beginBlobDownload(accountID: account, blobID: receipt.blobId) }
            try store.closeBlobDownload(downloadID: handle.downloadID)
        }
        // Exact UID reuse cannot inherit an old uploader's temporary bytes.
        accounts.aliceName = "replacement"
        _ = try store.configureAccess(
            .object([
                "profile": .text(AccessConfiguration.profile),
                "users": .list([.text("replacement"), .text("bob")]),
                "userAliases": .object(["alice": .text("replacement")]),
            ]), operationID: "identity-change")
        try store.withAccess(forUID: accounts.alice) {
            code("notFound") {
                try store.beginBlobDownload(accountID: account, blobID: privateReceipt.blobId)
            }
        }
    }
    private final class Credential: @unchecked Sendable {
        let account: AccountIdentity
        private let lock = NSLock()
        private var revoked = false
        init() throws { account = try SystemAccountDirectory().user(forUID: getuid()) }
        func revoke() { lock.withLock { revoked = true } }
        var context: JMAPHTTPAuthentication {
            .init(
                credentialID: "private-fixture-credential", uid: account.uid, principalName: account.name,
                expiresAt: Date().addingTimeInterval(3600),
                revalidate: { [self] in
                    guard !lock.withLock({ revoked }) else {
                        throw TractandaError("invalidSession", "Credential revoked.")
                    }
                    return account
                })
        }
    }
    func testProviderStreamingAttachStandardCopyReadOnlyAndRevokedCleanup() async throws {
        let root = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let credential = try Credential()
        let auth = credential.context
        let coordinator = try await ServiceCoordinator(
            opening: root, embeddingProviderForTesting: nil,
            attachmentUploadPolicy: .init(minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes))
        do {
            let account = try await coordinator.withJMAPAccess(authentication: auth) {
                try $0.nativeProtocolSessionBasis.identity
            }
            let service = JMAPBlobService(coordinator: coordinator, limits: try limits())
            let upload = try await service.beginUpload(
                accountID: account, type: "text/plain; charset=utf-8", expectedSize: nil, authentication: auth
            )
            try await upload.append(Data("streamed ".utf8))
            try await upload.append(Data("bytes".utf8))
            let done = try await upload.finish()
            let blob = try XCTUnwrap(done["blobId"]?.text)
            XCTAssertEqual(done["type"]?.text, "text/plain; charset=utf-8")
            let download = try await service.openDownload(
                accountID: account, blobID: blob, authentication: auth)
            let downloaded = try await download.read(offset: 0, limit: 262_144)
            XCTAssertEqual(downloaded, Data("streamed bytes".utf8))
            let base = try await coordinator.withJMAPAccess(authentication: auth) { store in
                try store.commit(.init(classID: "Item", operationID: "async-item")).revision
            }
            let intent = JMAPAttachBlobRequest(
                accountID: account, itemID: base.itemID, expectedRevisionID: base.revisionID,
                blobID: blob, filename: "text.txt", mediaType: "text/plain", operationID: "async-attach")
            let attached = try await service.attachBlob(intent, authentication: auth)
            let replay = try await service.attachBlob(intent, authentication: auth)
            XCTAssertEqual(replay.revisionID, attached.revisionID)
            XCTAssertTrue(replay.wasReplayed)
            let methods = try await service.methods(authentication: auth)
            func request(_ name: String, _ fields: [String: Any]) throws -> Data {
                try JSONSerialization.data(withJSONObject: [
                    "using": [JMAPKernel.core, TractandaJMAP.capability],
                    "methodCalls": [[name, fields, "call"]],
                ])
            }
            let accounts = [
                try JMAPAccountAccess(
                    accountID: account, capabilities: [TractandaJMAP.capability], isReadOnly: false)
            ]
            let kernel = JMAPKernel(
                methods: methods, accounts: accounts, sessionState: { try! .init("fixture") })
            let copied = try await kernel.execute(
                request(
                    "Blob/copy",
                    [
                        "accountId": account, "fromAccountId": account,
                        "blobIds": [blob, blob, "opaque-valid-id"],
                    ]))
            XCTAssertEqual(copied.methodResponses.first?.name, "Blob/copy")
            XCTAssertEqual(copied.methodResponses.first?.arguments["copied"]?[blob]?.text, blob)
            XCTAssertEqual(
                copied.methodResponses.first?.arguments["notCopied"]?["opaque-valid-id"]?["type"]?.text,
                "notFound")
            let wrongSource = try await kernel.execute(
                request("Blob/copy", ["accountId": account, "fromAccountId": "unknown", "blobIds": []]))
            XCTAssertEqual(wrongSource.methodResponses.first?.arguments["type"]?.text, "fromAccountNotFound")
            let tooMany = try await kernel.execute(
                request(
                    "Blob/copy",
                    [
                        "accountId": account, "fromAccountId": account,
                        "blobIds": (0...TractandaJMAP.maximumBlobIDsInCopy).map { "unknown-\($0)" },
                    ]))
            XCTAssertEqual(tooMany.methodResponses.first?.arguments["type"]?.text, "requestTooLarge")
            let readonly = JMAPKernel(
                methods: methods,
                accounts: [
                    try .init(accountID: account, capabilities: [TractandaJMAP.capability], isReadOnly: true)
                ],
                sessionState: { try! .init("fixture") })
            let rejected = try await readonly.execute(
                request("Blob/copy", ["accountId": account, "fromAccountId": account, "blobIds": [blob]]))
            XCTAssertEqual(rejected.methodResponses.first?.arguments["type"]?.text, "accountReadOnly")
            let partial = try await service.beginUpload(
                accountID: account, type: "text/plain", expectedSize: nil, authentication: auth)
            try await partial.append(Data("abandoned".utf8))
            credential.revoke()
            do {
                _ = try await download.read(offset: 0, limit: 1)
                XCTFail("Revoked credential read bytes")
            } catch { XCTAssertEqual((error as? TractandaError)?.code, "invalidSession") }
            await download.close()
            await partial.cancel()
            let payloadStages = root.appendingPathComponent("attachments/.staging")
            let remaining = try FileManager.default.contentsOfDirectory(atPath: payloadStages.path)
            // The completed raw blob remains; the disconnected incomplete body is gone.
            XCTAssertEqual(remaining.count, 1)
            await coordinator.close()
        } catch {
            await coordinator.close()
            throw error
        }
    }
}
