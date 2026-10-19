import Crypto
import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class AttachmentLifecycleTests: XCTestCase {
    override func setUpWithError() throws { try AttachmentFixtureCapacity.requireFree() }
    private func fixture() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "tractanda-attachment-" + Identifier.make())
    }
    private func item(_ store: ItemStore, operation: String = "create") throws -> Revision {
        try store.commit(
            CommitRequest(classID: "Item", changes: ["subject": .text("document")], operationID: operation)
        ).revision
    }
    private func request(_ base: Revision, bytes: Data, operation: String = "attach")
        -> AttachmentUploadRequest
    {
        AttachmentUploadRequest(
            itemID: base.itemID, expectedRevisionID: base.revisionID,
            operationID: operation, filename: "../résumé.pdf", mediaType: "application/pdf",
            byteCount: Int64(bytes.count),
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }
    private func attach(_ store: ItemStore, base: Revision, bytes: Data, operation: String = "attach") throws
        -> CommitResult
    {
        let upload = try store.beginAttachment(request(base, bytes: bytes, operation: operation))
        if let committed = upload.committed {
            return CommitResult(
                revision: try store.get(committed.itemID, revisionID: committed.revisionID),
                wasReplayed: committed.wasReplayed, isIndexReady: committed.isIndexReady,
                warnings: committed.warnings)
        }
        let id = try XCTUnwrap(upload.uploadID)
        var offset = 0
        while offset < bytes.count {
            let count = min(262_144, bytes.count - offset)
            _ = try store.appendAttachment(
                uploadID: id, offset: Int64(offset), data: bytes.subdata(in: offset..<offset + count))
            offset += count
        }
        return try store.finishAttachment(uploadID: id)
    }
    private func assertCode(
        _ code: String, _ expression: () throws -> Any, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) {
            XCTAssertEqual(($0 as? TractandaError)?.code, code, "\($0)", file: file, line: line)
        }
    }
    func testNativeChunksLostReplyReplayDetachAndHistoricalExport() throws {
        let root = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AttachmentFixtureCapacity.makeStore(root: root)
        let service = ItemService(store: store)
        let client = ItemClient(transport: { service.handle($0, peerUID: getuid()) })
        let base = try item(store)
        let bytes = Data((0..<262_161).map { UInt8($0 % 251) })
        let intent = request(base, bytes: bytes)
        let upload = try client.beginAttachment(intent)
        let id = try XCTUnwrap(upload.uploadID)
        XCTAssertEqual(
            try client.appendAttachment(uploadID: id, offset: 0, data: bytes.prefix(262_144)), 262_144)
        XCTAssertEqual(
            try client.appendAttachment(uploadID: id, offset: 0, data: bytes.prefix(262_144)), 262_144)
        XCTAssertEqual(
            try client.appendAttachment(uploadID: id, offset: 262_144, data: bytes.suffix(17)), 262_161)
        let committed = try client.finishAttachment(uploadID: id)
        assertCode("uploadExpired") { try client.finishAttachment(uploadID: id) }
        let replay = try client.beginAttachment(intent)
        XCTAssertNil(replay.uploadID)
        XCTAssertEqual(replay.committed?.revisionID, committed.revisionID)
        XCTAssertEqual(try store.history(base.itemID).count, 2)
        XCTAssertEqual(try client.listAttachments(itemID: base.itemID).attachments.count, 1)
        XCTAssertEqual(ItemTextContent.corpus(for: try store.get(base.itemID)).metadata, "")
        let descriptor = upload.attachment
        let output = root.appendingPathComponent("export.pdf")
        XCTAssertEqual(
            try AttachmentFiles.export(
                client: client, itemID: base.itemID,
                attachmentID: descriptor.attachmentID, destination: output), descriptor)
        XCTAssertEqual(try Data(contentsOf: output), bytes)
        let detached = try client.detachAttachment(
            itemID: base.itemID, expectedRevisionID: committed.revisionID,
            attachmentID: descriptor.attachmentID, operationID: "detach")
        XCTAssertTrue(
            try client.detachAttachment(
                itemID: base.itemID, expectedRevisionID: committed.revisionID,
                attachmentID: descriptor.attachmentID, operationID: "detach"
            ).wasReplayed)
        XCTAssertTrue(try client.listAttachments(itemID: base.itemID).attachments.isEmpty)
        XCTAssertEqual(detached.supersedes, committed.revisionID)
        XCTAssertEqual(
            try client.attachmentContent(
                itemID: base.itemID, revisionID: committed.revisionID,
                attachmentID: descriptor.attachmentID, offset: 262_144
            ).data, bytes.suffix(17))
    }
    func testGenericManifestWritesAndCrossItemGuessAreRejectedCopyIsIndependentAndReplaySafe() throws {
        let root = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AttachmentFixtureCapacity.makeStore(root: root)
        let base = try item(store)
        let result = try attach(store, base: base, bytes: Data("private original".utf8))
        let descriptor = try XCTUnwrap(AttachmentDescriptor.descriptors(in: result.revision.fields).first)
        assertCode("invalidAttachment") {
            try store.commit(
                CommitRequest(
                    classID: "Item",
                    changes: ["attachments": .list([descriptor.itemValue])], operationID: "steal"))
        }
        assertCode("invalidAttachment") {
            try store.commit(
                CommitRequest(
                    action: .revise,
                    itemID: base.itemID, expectedRevisionID: result.revision.revisionID,
                    unset: ["attachments"], operationID: "forge"))
        }
        let other = try item(store, operation: "other")
        assertCode("notFound") {
            try store.attachmentContent(itemID: other.itemID, attachmentID: descriptor.attachmentID)
        }
        let copyRequest = CommitRequest(
            action: .copy, itemID: base.itemID, expectedRevisionID: result.revision.revisionID,
            operationID: "copy")
        let copy = try store.commit(copyRequest)
        let copied = try XCTUnwrap(AttachmentDescriptor.descriptors(in: copy.revision.fields).first)
        XCTAssertNotEqual(copied.attachmentID, descriptor.attachmentID)
        XCTAssertEqual(copied.sha256, descriptor.sha256)
        XCTAssertEqual(
            try store.attachmentContent(itemID: copy.revision.itemID, attachmentID: copied.attachmentID).data,
            Data("private original".utf8))
        XCTAssertTrue(try store.commit(copyRequest).wasReplayed)
        XCTAssertEqual(try store.commit(copyRequest).revision.revisionID, copy.revision.revisionID)
    }
    func testInterruptedPublicationCASAndRestartResumesStaging() throws {
        let root = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var store: ItemStore? = try AttachmentFixtureCapacity.makeStore(root: root)
        let base = try item(XCTUnwrap(store))
        let bytes = Data("published original".utf8)
        let intent = request(base, bytes: bytes)
        let upload = try XCTUnwrap(store).beginAttachment(intent)
        let id = try XCTUnwrap(upload.uploadID)
        _ = try XCTUnwrap(store).appendAttachment(uploadID: id, offset: 0, data: bytes)
        store?.beforeAttachmentCommitForTesting = { throw TractandaError("injected", "after publication") }
        assertCode("injected") { try XCTUnwrap(store).finishAttachment(uploadID: id) }
        XCTAssertEqual(try store?.get(base.itemID).revisionID, base.revisionID)
        store?.beforeAttachmentCommitForTesting = nil
        let finished = try XCTUnwrap(store).finishAttachment(uploadID: id)
        let incomplete = try XCTUnwrap(store).beginAttachment(
            request(finished.revision, bytes: bytes, operation: "unfinished"))
        _ = try XCTUnwrap(store).appendAttachment(
            uploadID: XCTUnwrap(incomplete.uploadID), offset: 0, data: bytes.prefix(3))
        store = nil
        store = try AttachmentFixtureCapacity.makeStore(root: root)
        assertCode("uploadExpired") { try XCTUnwrap(store).finishAttachment(uploadID: id) }
        let replay = try XCTUnwrap(store).beginAttachment(intent)
        XCTAssertEqual(replay.committed?.revisionID, finished.revision.revisionID)
        let restarted = try XCTUnwrap(store).beginAttachment(
            request(finished.revision, bytes: bytes, operation: "unfinished"))
        XCTAssertEqual(restarted.offset, 3)
        let changed = try XCTUnwrap(store).commit(
            CommitRequest(
                action: .revise, itemID: base.itemID,
                expectedRevisionID: finished.revision.revisionID, changes: ["body": .text("intervening")],
                operationID: "edit"))
        _ = try XCTUnwrap(store).appendAttachment(
            uploadID: XCTUnwrap(restarted.uploadID), offset: 3, data: bytes.dropFirst(3))
        assertCode("revisionConflict") {
            try XCTUnwrap(store).finishAttachment(uploadID: XCTUnwrap(restarted.uploadID))
        }
        XCTAssertEqual(try store?.get(base.itemID).revisionID, changed.revision.revisionID)
    }
    func testCanonicalOnlyBackupAndIndexRebuildRetainOriginalsAndRejectMissingBytes() throws {
        let root = fixture()
        let restored = fixture()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: restored)
        }
        var store: ItemStore? = try AttachmentFixtureCapacity.makeStore(root: root)
        let base = try item(XCTUnwrap(store))
        let bytes = Data("restore me".utf8)
        let attached = try attach(XCTUnwrap(store), base: base, bytes: bytes)
        let descriptor = try XCTUnwrap(AttachmentDescriptor.descriptors(in: attached.revision.fields).first)
        try store?.rebuildIndex()
        XCTAssertEqual(
            try store?.attachmentContent(itemID: base.itemID, attachmentID: descriptor.attachmentID).data,
            bytes)
        store = nil
        try FileManager.default.copyItem(at: root, to: restored)
        try FileManager.default.removeItem(at: restored.appendingPathComponent("index"))
        let recovered = try AttachmentFixtureCapacity.makeStore(root: restored)
        XCTAssertEqual(
            try recovered.attachmentContent(itemID: base.itemID, attachmentID: descriptor.attachmentID).data,
            bytes)
        let helper = try AttachmentPayloadStore(root: restored, ownerUID: getuid())
        let payload = try helper.payloadURL(for: descriptor.attachmentID)
        try FileManager.default.removeItem(at: payload)
        XCTAssertThrowsError(try recovered.rebuildIndex())
        assertCode("recoveryRequired") { try recovered.get(base.itemID) }
    }
    func testUploadLimitsExpirationMismatchAndAbort() throws {
        let root = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AttachmentFixtureCapacity.makeStore(root: root)
        let base = try item(store)
        let bytes = Data("one".utf8)
        let intent = request(base, bytes: bytes)
        let upload = try store.beginAttachment(intent)
        let id = try XCTUnwrap(upload.uploadID)
        assertCode("operationMismatch") { try store.beginAttachment(request(base, bytes: Data("two".utf8))) }
        assertCode("invalidArguments") { try store.appendAttachment(uploadID: id, offset: 2, data: bytes) }
        for ordinal in 1..<8 {
            _ = try store.beginAttachment(request(base, bytes: bytes, operation: "upload\(ordinal)"))
        }
        assertCode("resourceLimit") {
            try store.beginAttachment(request(base, bytes: bytes, operation: "overflow"))
        }
        store.attachmentClockForTesting = { Date().addingTimeInterval(3_601) }
        assertCode("uploadExpired") { try store.finishAttachment(uploadID: id) }
        let retry = try store.beginAttachment(intent)
        try store.abortAttachment(uploadID: XCTUnwrap(retry.uploadID))
        assertCode("uploadExpired") { try store.finishAttachment(uploadID: XCTUnwrap(retry.uploadID)) }
    }
    func testCLIFileHelperRejectsSourceSymlinkAndProtectsDestinationOnIntegrityFailure() throws {
        let root = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AttachmentFixtureCapacity.makeStore(root: root)
        let base = try item(store)
        let source = root.appendingPathComponent("source")
        let link = root.appendingPathComponent("link")
        try Data("source".utf8).write(to: source)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let service = ItemService(store: store)
        let client = ItemClient(transport: { service.handle($0, peerUID: getuid()) })
        assertCode("fileReadFailed") {
            try AttachmentFiles.attach(
                client: client, source: link,
                itemID: base.itemID, expectedRevisionID: base.revisionID, operationID: "symlink")
        }
        let result = try AttachmentFiles.attach(
            client: client, source: source,
            itemID: base.itemID, expectedRevisionID: base.revisionID, operationID: "real")
        let descriptor = try XCTUnwrap(
            AttachmentDescriptor.descriptors(in: try store.get(result.itemID).fields).first)
        let bad = ItemClient(transport: { data in
            let response = service.handle(data, peerUID: getuid())
            var object = try JSONSerialization.jsonObject(with: response) as! [String: Any]
            var calls = object["methodResponses"] as! [[Any]]
            if calls[0][0] as? String == "TractandaAttachment/content" {
                var payload = calls[0][1] as! [String: Any]
                payload["data"] = Data("broken".utf8).base64EncodedString()
                calls[0][1] = payload
                object["methodResponses"] = calls
                return try JSONSerialization.data(withJSONObject: object)
            }
            return response
        })
        let destination = root.appendingPathComponent("output")
        assertCode("attachmentIntegrity") {
            try AttachmentFiles.export(
                client: bad, itemID: base.itemID,
                attachmentID: descriptor.attachmentID, destination: destination)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
    func testResumableNativeExportPinsStoreAndRechecksCurrentACLForCompleteHistory() throws {
        let root = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = Accounts()
        let store = try AttachmentFixtureCapacity.makeStore(root: root, accounts: accounts)
        _ = try store.configureAccess(
            .object([
                "profile": .text(AccessConfiguration.profile),
                "users": .list([.text("alice"), .text("bob")]),
            ]),
            operationID: "download-config")
        let base = try store.withAccess(forUID: accounts.alice) {
            try store.commit(
                CommitRequest(
                    classID: "Item", changes: ["permissions": permissions(owner: "alice", mode: 0o640)],
                    operationID: "download-create")
            ).revision
        }
        let bytes = Data(repeating: 17, count: 262_157)
        let attached = try store.withAccess(forUID: accounts.alice) {
            try attach(store, base: base, bytes: bytes)
        }.revision
        let descriptor = try XCTUnwrap(AttachmentDescriptor.descriptors(in: attached.fields).first)
        let service = ItemService(store: store)
        let client = ItemClient(transport: { service.handle($0, peerUID: accounts.bob) })
        let connection = ServerConnection(socketPath: "/tmp/download-fixture.sock")
        let stage = root.appendingPathComponent("retained-download")
        let destination = root.appendingPathComponent("download")
        let policy = AttachmentDownloadPolicy(
            maximumStagedBytes: 4 * 1024 * 1024, minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes)
        func download(_ hooks: ResumableByteDownload.Hooks = .init()) throws -> AttachmentDescriptor {
            try AttachmentFiles.exportResumable(
                client: client, connection: connection, itemID: base.itemID,
                attachmentID: descriptor.attachmentID, destination: destination,
                revisionID: attached.revisionID, resumeDirectory: stage, policy: policy, hooks: hooks)
        }
        let list = try client.listAttachments(itemID: base.itemID)
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(list.storeID))?.version1Components)
        XCTAssertEqual(
            try client.attachmentContent(itemID: base.itemID, attachmentID: descriptor.attachmentID).storeID,
            list.storeID)
        assertCode("connectionLost") {
            try download(
                .init(afterCheckpoint: { _ in throw TractandaError("connectionLost", "Interrupted") }))
        }
        let revoked = try store.commit(
            CommitRequest(
                action: .revise, itemID: base.itemID, expectedRevisionID: attached.revisionID,
                changes: ["permissions": permissions(owner: "alice", mode: 0o600)],
                operationID: "download-revoke"))
        assertCode("forbidden") { try download() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let restored = try store.commit(
            CommitRequest(
                action: .revise, itemID: base.itemID, expectedRevisionID: revoked.revision.revisionID,
                changes: ["permissions": permissions(owner: "alice", mode: 0o640)],
                operationID: "download-restore"))
        XCTAssertEqual(try download(), descriptor)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        _ = try store.commit(
            CommitRequest(
                action: .revise, itemID: base.itemID, expectedRevisionID: restored.revision.revisionID,
                changes: ["permissions": permissions(owner: "alice", mode: 0o600)],
                operationID: "download-revoke-again"))
        assertCode("forbidden") { try download() }
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
    }
    func testResumableNativeExportRejectsMissingAndChangedServerIdentity() throws {
        let root = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AttachmentFixtureCapacity.makeStore(root: root)
        let base = try item(store)
        let attached = try attach(store, base: base, bytes: Data([1, 2, 3])).revision
        let descriptor = try XCTUnwrap(AttachmentDescriptor.descriptors(in: attached.fields).first)
        let service = ItemService(store: store)
        func client(missing: Bool) -> ItemClient {
            ItemClient(transport: { request in
                let response = service.handle(request, peerUID: getuid())
                var object = try JSONSerialization.jsonObject(with: response) as! [String: Any]
                var responses = object["methodResponses"] as! [[Any]]
                let method = responses[0][0] as! String
                if missing || method == "TractandaAttachment/content" {
                    var result = responses[0][1] as! [String: Any]
                    if missing {
                        result.removeValue(forKey: "storeID")
                    } else {
                        result["storeID"] = "22222222-2222-1222-8222-222222222222"
                    }
                    responses[0][1] = result
                    object["methodResponses"] = responses
                }
                return try JSONSerialization.data(withJSONObject: object)
            })
        }
        for missing in [true, false] {
            assertCode(missing ? "downloadBinding" : "downloadIntegrity") {
                try AttachmentFiles.exportResumable(
                    client: client(missing: missing),
                    connection: ServerConnection(socketPath: "/tmp/test.sock"),
                    itemID: base.itemID, attachmentID: descriptor.attachmentID,
                    destination: root.appendingPathComponent("download"), revisionID: attached.revisionID,
                    resumeDirectory: root.appendingPathComponent("retained"),
                    policy: AttachmentDownloadPolicy(
                        maximumStagedBytes: 4 * 1024 * 1024,
                        minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes))
            }
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: root.appendingPathComponent("download").path))
        }
    }
    private final class Accounts: AccountDirectory {
        let alice: UInt32 = 60001, bob: UInt32 = 60002
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            let name: String
            switch uid {
            case getuid(): name = "admin"
            case alice: name = "alice"
            case bob: name = "bob"
            default: throw TractandaError("unresolvedPrincipal", "Unknown user")
            }
            return AccountIdentity(uid: uid, name: name, primaryGroupName: "staff", groupIDs: [70001])
        }
        func user(named name: String) throws -> AccountIdentity {
            switch name {
            case "admin": return try user(forUID: getuid())
            case "alice": return try user(forUID: alice)
            case "bob": return try user(forUID: bob)
            default: throw TractandaError("unresolvedPrincipal", "Unknown user")
            }
        }
        func groupID(named name: String) throws -> UInt32 {
            guard name == "staff" else { throw TractandaError("unresolvedPrincipal", "Unknown group") }
            return 70001
        }
    }
    private func permissions(owner: String, mode: Int64) -> ItemValue {
        .object([
            "profile": .text(ItemPermissions.profile), "owner": .text(owner),
            "group": .text("staff"), "mode": .integer(mode), "acl": .object([:]),
        ])
    }
    func testCurrentACLRevocationDeniesOriginalsHistoryCopyAndFinishBeforePayloadIO() throws {
        let root = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = Accounts()
        let store = try AttachmentFixtureCapacity.makeStore(root: root, accounts: accounts)
        _ = try store.configureAccess(
            .object([
                "profile": .text(AccessConfiguration.profile),
                "users": .list([.text("alice"), .text("bob")]),
            ]), operationID: "config")
        let base = try store.withAccess(forUID: accounts.alice) {
            try store.commit(
                CommitRequest(
                    classID: "Item", changes: ["permissions": permissions(owner: "alice", mode: 0o640)],
                    operationID: "alice-create")
            ).revision
        }
        let bytes = Data("secret".utf8)
        let attached = try store.withAccess(forUID: accounts.alice) {
            try attach(store, base: base, bytes: bytes)
        }
        let descriptor = try XCTUnwrap(AttachmentDescriptor.descriptors(in: attached.revision.fields).first)
        try store.withAccess(forUID: accounts.bob) {
            XCTAssertEqual(
                try store.attachmentContent(itemID: base.itemID, attachmentID: descriptor.attachmentID).data,
                bytes)
            assertCode("forbidden") {
                try store.beginAttachment(request(attached.revision, bytes: bytes, operation: "bob-edit"))
            }
        }
        let pending = try store.withAccess(forUID: accounts.alice) {
            let upload = try store.beginAttachment(
                request(attached.revision, bytes: bytes, operation: "pending"))
            _ = try store.appendAttachment(uploadID: XCTUnwrap(upload.uploadID), offset: 0, data: bytes)
            return upload
        }
        let readonly = try store.commit(
            CommitRequest(
                action: .revise, itemID: base.itemID,
                expectedRevisionID: attached.revision.revisionID,
                changes: ["permissions": permissions(owner: "admin", mode: 0o640)], operationID: "readonly"))
        try store.withAccess(forUID: accounts.alice) {
            XCTAssertEqual(
                try store.beginAttachment(request(base, bytes: bytes)).committed?.revisionID,
                attached.revision.revisionID)
            assertCode("forbidden") { try store.finishAttachment(uploadID: XCTUnwrap(pending.uploadID)) }
        }
        _ = try store.commit(
            CommitRequest(
                action: .revise, itemID: base.itemID,
                expectedRevisionID: readonly.revision.revisionID,
                changes: ["permissions": permissions(owner: "admin", mode: 0o600)], operationID: "revoke"))
        try store.withAccess(forUID: accounts.alice) {
            assertCode("forbidden") { try store.beginAttachment(request(base, bytes: bytes)) }
        }
        try store.withAccess(forUID: accounts.bob) {
            assertCode("forbidden") { try store.beginAttachment(request(base, bytes: bytes)) }
        }
        let helper = try AttachmentPayloadStore(root: root, ownerUID: getuid())
        let payload = try helper.payloadURL(for: descriptor.attachmentID)
        try FileManager.default.removeItem(at: payload)
        for uid in [accounts.alice, accounts.bob] {
            try store.withAccess(forUID: uid) {
                assertCode("forbidden") {
                    try store.listAttachments(itemID: base.itemID, revisionID: attached.revision.revisionID)
                }
                assertCode("forbidden") {
                    try store.attachmentContent(
                        itemID: base.itemID, revisionID: attached.revision.revisionID,
                        attachmentID: descriptor.attachmentID)
                }
                assertCode("forbidden") { try store.history(base.itemID) }
                assertCode("forbidden") {
                    try store.commit(
                        CommitRequest(
                            action: .copy, itemID: base.itemID,
                            expectedRevisionID: attached.revision.revisionID, operationID: "unauthorized-copy"
                        ))
                }
            }
        }
        try store.withAccess(forUID: accounts.alice) {
            assertCode("forbidden") { try store.finishAttachment(uploadID: XCTUnwrap(pending.uploadID)) }
        }
        try store.withAccess(forUID: accounts.bob) {
            assertCode("uploadExpired") { try store.finishAttachment(uploadID: XCTUnwrap(pending.uploadID)) }
        }
    }

    func testCanonicalRecoveryRejectsAttachmentOwnershipRebinding() throws {
        let root = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AttachmentFixtureCapacity.makeStore(root: root)
        let base = try item(store)
        let attached = try attach(store, base: base, bytes: Data("owned".utf8))
        let other = try item(store, operation: "other-owner")
        var forgedFields = other.fields
        forgedFields["attachments"] = attached.revision.fields["attachments"]
        var ancestry = try XCTUnwrap(forgedFields["revisionAncestry"]?.map)
        let writes = try XCTUnwrap(other.provenance).writtenFields
        ancestry["writtenFields"] = .list(Array(Set(writes + ["attachments"])).sorted().map(ItemValue.text))
        forgedFields["revisionAncestry"] = .object(ancestry)
        let forged = try Revision(fields: forgedFields, formatVersion: other.formatVersion)
        let records = FileManager.default.enumerator(
            at: root.appendingPathComponent("items"), includingPropertiesForKeys: nil)
        var target: URL?
        while let url = records?.nextObject() as? URL {
            if url.lastPathComponent == other.revisionID + ".tractanda" {
                target = url
                break
            }
        }
        let record = try XCTUnwrap(target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: record.path)
        try RecordCodec.encode(forged).write(to: record)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: record.path)
        assertCode("recoveryError") { try store.rebuildIndex() }
        assertCode("recoveryRequired") { try store.get(other.itemID) }
    }

    func testSuccessfulImportsFreeTransferCapacityAndRecoveryHashesEachIdentityOnce() throws {
        let root = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AttachmentFixtureCapacity.makeStore(root: root)
        var current = try item(store)
        for ordinal in 0..<10 {
            current = try attach(
                store, base: current, bytes: Data([UInt8(ordinal)]), operation: "serial\(ordinal)"
            ).revision
        }
        for ordinal in 0..<5 {
            current = try store.commit(
                CommitRequest(
                    action: .revise, itemID: current.itemID,
                    expectedRevisionID: current.revisionID, changes: ["body": .text("revision\(ordinal)")],
                    operationID: "history\(ordinal)")
            ).revision
        }
        try store.rebuildIndex()
        XCTAssertEqual(store.attachmentRecoveryValidationsForTesting, 10)
        XCTAssertEqual(try store.listAttachments(itemID: current.itemID).attachments.count, 10)
    }

    func testExternalIndexAliasCannotCreateFilesInsideAttachmentSubtree() throws {
        let root = fixture()
        let alias = fixture()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: alias)
        }
        let originals = root.appendingPathComponent("attachments/payloads", isDirectory: true)
        try FileManager.default.createDirectory(
            at: originals, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: originals)
        assertCode("invalidIndexDirectory") {
            try ItemStore(
                root: root,
                indexDirectory: alias.appendingPathComponent("absent-index", isDirectory: true))
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: originals.appendingPathComponent("absent-index/items.sqlite").path))
    }

    func testAttachmentReceiptsFitSmallBudgetRegardlessOfParentBody() throws {
        let root = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AttachmentFixtureCapacity.makeStore(root: root)
        let base = try store.commit(
            CommitRequest(
                classID: "Item",
                changes: ["body": .text(String(repeating: "large parent content ", count: 6_000))],
                operationID: "large-parent")
        ).revision
        let service = ItemService(store: store)
        let client = ItemClient(transport: { request in
            let response = service.handle(request, peerUID: getuid())
            guard response.count <= 8_192 else {
                throw TractandaError(
                    "responseTooLarge", "Fixture's small lifecycle response budget exceeded.")
            }
            let object = try JSONSerialization.jsonObject(with: response) as! [String: Any]
            let calls = object["methodResponses"] as! [[Any]]
            let payload = calls[0][1] as! [String: Any]
            XCTAssertNil(payload["revision"])
            XCTAssertNil(payload["fields"])
            return response
        })
        let bytes = Data("tiny original".utf8)
        let intent = request(base, bytes: bytes)
        let upload = try client.beginAttachment(intent)
        let id = try XCTUnwrap(upload.uploadID)
        _ = try client.appendAttachment(uploadID: id, offset: 0, data: bytes)
        let attached = try client.finishAttachment(uploadID: id)
        XCTAssertEqual(attached.itemID, base.itemID)
        XCTAssertEqual(attached.supersedes, base.revisionID)
        XCTAssertEqual(try client.beginAttachment(intent).committed?.revisionID, attached.revisionID)
        let detached = try client.detachAttachment(
            itemID: base.itemID, expectedRevisionID: attached.revisionID,
            attachmentID: upload.attachment.attachmentID, operationID: "detach-large")
        XCTAssertEqual(detached.supersedes, attached.revisionID)
        XCTAssertTrue(
            try client.detachAttachment(
                itemID: base.itemID, expectedRevisionID: attached.revisionID,
                attachmentID: upload.attachment.attachmentID, operationID: "detach-large"
            ).wasReplayed)
        XCTAssertEqual(try store.get(base.itemID).fields["body"], base.fields["body"])
    }

}
