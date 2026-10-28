import CTractandaPlatform
import Foundation
import XCTest

@testable import TractandaCore
@testable import TractandaServer

final class PersonalEntrypointTests: XCTestCase, @unchecked Sendable {
    private final class Accounts: AccountDirectory, @unchecked Sendable {
        let bob: UInt32 = 54002
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            guard uid == tractanda_uid() || uid == bob else {
                throw TractandaError("unresolvedPrincipal", "Fixture user missing")
            }
            return .init(
                uid: uid, name: uid == bob ? "bob" : "owner", primaryGroupName: "staff", groupIDs: [72001])
        }
        func user(named name: String) throws -> AccountIdentity {
            if name == "owner" { return try user(forUID: tractanda_uid()) }
            if name == "bob" { return try user(forUID: bob) }
            throw TractandaError("unresolvedPrincipal", "Fixture user missing")
        }
        func groupID(named name: String) throws -> UInt32 {
            guard name == "staff" else {
                throw TractandaError("unresolvedPrincipal", "Fixture group missing")
            }
            return 72001
        }
    }
    private final class Flags: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func touch() {
            lock.lock()
            count += 1
            lock.unlock()
        }
        func value() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
        func first() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if count != 0 { return false }
            count = 1
            return true
        }
    }
    private actor Gate {
        private var entered = false
        private var finished = false
        private var open = false
        private var entry: CheckedContinuation<Bool, Never>?
        private var releaseWaiter: CheckedContinuation<Void, Never>?
        func pause() async {
            entered = true
            entry?.resume(returning: true)
            entry = nil
            if !open { await withCheckedContinuation { releaseWaiter = $0 } }
        }
        func waitForEntry() async -> Bool {
            if entered { return true }
            if finished { return false }
            return await withCheckedContinuation { entry = $0 }
        }
        func complete() {
            finished = true
            if !entered {
                entry?.resume(returning: false)
                entry = nil
            }
        }
        func release() {
            open = true
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }
    private func root() throws -> URL {
        // Few tiny records/indexes, estimated below16MiB; retain genuine10GiB plus128MiB fixture cap.
        try PeerFixtureCapacity.requireFree(at: FileManager.default.temporaryDirectory)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tep-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }
    private func policy(_ users: [String] = ["owner", "bob"]) -> ItemValue {
        .object(["profile": .text(AccessConfiguration.profile), "users": .list(users.map(ItemValue.text))])
    }
    private func permissions(_ mode: Int64 = 0o644) -> ItemValue {
        .object([
            "profile": .text(ItemPermissions.profile), "owner": .text("owner"), "group": .text("staff"),
            "mode": .integer(mode), "acl": .object([:]),
        ])
    }
    private func request(_ method: String, _ args: [String: Any] = [:]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "using": [ItemService.capability], "methodCalls": [[method, args, "client"]],
        ])
    }
    private func call(_ socket: String, _ method: String, _ args: [String: Any] = [:]) async throws -> Data {
        let bytes = try JSONSerialization.data(withJSONObject: args)
        return try await Task.detached {
            let arguments = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            return try ItemClient(socketPath: socket).call(method, arguments: arguments)
        }.value
    }
    private func commit(_ socket: String, _ request: CommitRequest) async throws -> CommitResult {
        try await Task.detached {
            let client = ItemClient(socketPath: socket)
            let receipt = try client.commit(request)
            let revision = try client.revision(itemID: receipt.itemID, revisionID: receipt.revisionID)
            return CommitResult(
                revision: revision, wasReplayed: receipt.wasReplayed,
                isIndexReady: receipt.isIndexReady, warnings: receipt.diagnostics.map(\.rawValue))
        }.value
    }
    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func configuration(_ parent: URL) -> DaemonConfiguration {
        .init(
            storePath: parent.appendingPathComponent("d").path,
            socketPath: parent.appendingPathComponent("s").path,
            httpPort: nil,
            attachmentUploadPolicy: .init(minimumFreeBytes: Int64(PeerFixtureCapacity.reserveBytes)),
            rebuildNoProgressTimeoutSeconds: 1800)
    }

    func testPublicDefaultCreationAndStrictExistingMigrationBoundary() throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let personal = parent.appendingPathComponent("personal")
        do {
            let store = try ItemStore.initializeFresh(root: personal)
            XCTAssertTrue(store.isPersonalWorkgroup)
        }
        do {
            let store = try ItemStore.openInitialized(root: personal)
            XCTAssertTrue(store.isPersonalWorkgroup)
        }
        try ItemStore.verifyPersonalWorkgroupRoot(root: personal, ownerUID: tractanda_uid())
        XCTAssertThrowsError(
            try ItemStore.verifyPersonalWorkgroupRoot(root: personal, ownerUID: tractanda_uid() == 1 ? 2 : 1))
        let legacy = parent.appendingPathComponent("legacy")
        do { _ = try ItemStore(root: legacy) }
        let identity = try Data(contentsOf: legacy.appendingPathComponent(".tractanda-store-identity.json"))
        XCTAssertThrowsError(try ItemStore.openInitialized(root: legacy)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "personalMigrationRequired")
        }
        XCTAssertEqual(
            try Data(contentsOf: legacy.appendingPathComponent(".tractanda-store-identity.json")), identity)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: legacy.appendingPathComponent(".tractanda-personal-profile.json").path))
    }

    func testPrivateSocketClientCRUDHistoryRebuildRestartAndDerivedLoss() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let config = configuration(parent)
        do { _ = try ItemStore.initializeFresh(root: URL(fileURLWithPath: config.storePath)) }
        var daemon: SharedDaemon? = try await SharedDaemon.start(configuration: config)
        do {
            let info = try object(await call(config.socketPath, "TractandaStore/info"))
            XCTAssertEqual(info["persistenceProfile"] as? String, "personal-workgroup")
            XCTAssertEqual((info["clustering"] as? [String: Any])?["state"] as? String, "standalone")
            let active = try JSON.decode(
                CanonicalFormatSupport.self,
                JSONSerialization.data(withJSONObject: try XCTUnwrap(info["activeCanonicalFormats"])))
            XCTAssertEqual(active, .personalWorkgroup)
            let first = try await commit(
                config.socketPath,
                .init(
                    classID: "Item", changes: ["subject": .text("socketneedle")], operationID: "socket-create"
                ))
            let query = try object(await Task.detached {
                try ItemClient(socketPath: config.socketPath).query(criteria: ["expression": "subject == \"socketneedle\""])
            }.value)
            XCTAssertEqual(query["ids"] as? [String], [first.revision.itemID])
            let changed = try await commit(
                config.socketPath,
                .init(
                    action: .revise, itemID: first.revision.itemID,
                    expectedRevisionID: first.revision.revisionID,
                    changes: ["subject": .text("socketsecond")], operationID: "socket-revise"))
            let history = try await Task.detached {
                try ItemClient(socketPath: config.socketPath).history(itemID: first.revision.itemID)
            }.value
            XCTAssertEqual(history.list, [changed.revision, first.revision])
            var rebuild = try await Task.detached {
                try ItemClient(socketPath: config.socketPath).beginStoreRebuild(operationID: "socket-rebuild")
            }.value
            while !rebuild.isTerminal {
                try await Task.sleep(for: .milliseconds(20))
                let job = rebuild.jobID
                rebuild = try await Task.detached {
                    try ItemClient(socketPath: config.socketPath).storeRebuildStatus(jobID: job)
                }.value
            }
            XCTAssertEqual(rebuild.state, "completed")
            XCTAssertTrue(rebuild.indexTrusted)
            XCTAssertGreaterThan(rebuild.recordsVerified, 0)
            XCTAssertGreaterThan(rebuild.itemsProjected, 0)
            await daemon!.close()
            daemon = nil
            try FileManager.default.removeItem(
                at: URL(fileURLWithPath: config.storePath).appendingPathComponent("index"))
            daemon = try await SharedDaemon.start(configuration: config)
            let restored = try await Task.detached {
                try ItemClient(socketPath: config.socketPath).revision(for: first.revision.itemID)
            }.value
            XCTAssertEqual(restored, changed.revision)
            let restoredHistory = try await Task.detached {
                try ItemClient(socketPath: config.socketPath).history(itemID: first.revision.itemID)
            }.value
            XCTAssertEqual(restoredHistory.list, [changed.revision, first.revision])
            await daemon!.close()
            daemon = nil
            XCTAssertFalse(FileManager.default.fileExists(atPath: config.socketPath))
        } catch {
            await daemon?.close()
            throw error
        }
    }

    func testLocalPolicyRPCRejectsNonadminInvalidatesQueryAndPreservesCurrentACLResolve() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let accounts = Accounts()
        let config = configuration(parent)
        do {
            _ = try ItemStore.initializeFresh(
                root: URL(fileURLWithPath: config.storePath), accounts: accounts,
                initialAccessConfiguration: policy())
        }
        var daemon: SharedDaemon? = try await SharedDaemon.startForTesting(
            configuration: config, makeAccountDirectory: { accounts })
        let gate = Gate()
        do {
            let coordinator = await daemon!.coordinatorForTesting()
            let person = try await commit(
                config.socketPath,
                .init(
                    classID: "NaturalPersonItem",
                    changes: ["mobilePhone": .text("private-number"), "permissions": permissions(0o600)],
                    operationID: "person"))
            let role = try await commit(
                config.socketPath,
                .init(
                    classID: "RoleItem",
                    changes: [
                        "phone": .text("office-number"), "permissions": permissions(),
                        "holdings": .list([
                            .object([
                                "key": .text("term"), "start": .date("2020-01-01T00:00:00Z"),
                                "holder": .reference(ItemReference(person.revision.itemID)),
                            ])
                        ]),
                    ], operationID: "role"))
            let resolveRequest = try request(
                "TractandaItem/resolve", ["itemID": role.revision.itemID, "path": "holder.mobilePhone"])
            let denied = try NativeMethodResult.unwrap(
                await coordinator.handle(resolveRequest, forUID: accounts.bob),
                method: "TractandaItem/resolve")
            XCTAssertEqual(try object(denied)["status"] as? String, "accessDenied")
            let initial = try await commit(
                config.socketPath,
                .init(
                    classID: "Item",
                    changes: ["subject": .text("acl-history"), "permissions": permissions()],
                    operationID: "acl-item"))
            _ = try await commit(
                config.socketPath,
                .init(
                    action: .revise, itemID: initial.revision.itemID,
                    expectedRevisionID: initial.revision.revisionID,
                    changes: ["permissions": permissions(0o600)], operationID: "acl-revoke"))
            let history = try request("TractandaItem/history", ["itemID": initial.revision.itemID])
            let deniedHistory = try await coordinator.handle(history, forUID: accounts.bob)
            XCTAssertThrowsError(
                try NativeMethodResult.unwrap(deniedHistory, method: "TractandaItem/history")
            ) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "forbidden")
            }
            let newPolicy = try JSONSerialization.jsonObject(with: JSON.encode(policy(["owner"])))
            let configure = try request("TractandaStore/configureAccess", ["configuration": newPolicy])
            let nonadmin = try await coordinator.handle(configure, forUID: accounts.bob)
            XCTAssertThrowsError(
                try NativeMethodResult.unwrap(nonadmin, method: "TractandaStore/configureAccess")
            ) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "forbidden")
            }
            await coordinator.setPooledReadBeforeFinishHookForTesting { await gate.pause() }
            let query = try request("TractandaItem/query", ["expression": "classID == \"RoleItem\""])
            let pending = Task {
                do {
                    let response = try await coordinator.handle(query, forUID: accounts.bob)
                    await gate.complete()
                    return response
                } catch {
                    await gate.complete()
                    throw error
                }
            }
            let pooled = await gate.waitForEntry()
            XCTAssertTrue(pooled, "The query must capture old admission before policy replacement")
            let acknowledgement = try object(
                await call(config.socketPath, "TractandaStore/configureAccess", ["configuration": newPolicy]))
            XCTAssertEqual(acknowledgement["configured"] as? Bool, true)
            await gate.release()
            let stale = try await pending.value
            XCTAssertThrowsError(try NativeMethodResult.unwrap(stale, method: "TractandaItem/query")) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "forbidden")
            }
            await daemon!.close()
            daemon = nil
            daemon = try await SharedDaemon.startForTesting(
                configuration: config, makeAccountDirectory: { accounts })
            let reopened = await daemon!.coordinatorForTesting()
            let rejected = try await reopened.handle(query, forUID: accounts.bob)
            XCTAssertThrowsError(try NativeMethodResult.unwrap(rejected, method: "TractandaItem/query")) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "forbidden")
            }
            await daemon!.close()
            daemon = nil
        } catch {
            await gate.release()
            await daemon?.close()
            throw error
        }
    }

    func testConfiguredPeerRefusesBeforeStoreSocketAndReadiness() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = parent.appendingPathComponent("must-not-open")
        let socket = parent.appendingPathComponent("s")
        let fake = parent.appendingPathComponent("old-peer.json")
        try Data("invalid old peer config must not be decoded".utf8).write(to: fake)
        let opened = Flags()
        let ready = Flags()
        do {
            _ = try await SharedDaemon.startForTesting(
                configuration: .init(
                    storePath: store.path, socketPath: socket.path,
                    httpPort: 0, peerRuntimeConfigurationPath: fake.path),
                makeAccountDirectory: {
                    opened.touch()
                    return Accounts()
                },
                claimStartupReadiness: {
                    ready.touch()
                    return true
                })
            XCTFail("Configured peers must be refused")
        } catch { XCTAssertEqual((error as? TractandaError)?.code, "invalidConfiguration") }
        XCTAssertEqual(opened.value(), 0)
        XCTAssertEqual(ready.value(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))
    }

    func testRebuildCancelDuringSavedPageReadPreservesCanonicalAndNeverPublishesPartialIndex() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let config = configuration(parent)
        let storeRoot = URL(fileURLWithPath: config.storePath)
        do {
            let store = try ItemStore.initializeFresh(root: storeRoot)
            let item = try store.commit(.init(classID: "Item", operationID: "cancel-item")).revision
            let original = Data([137, 80, 78, 71, 13, 10, 26, 10])
            let upload = try store.beginAttachment(
                .init(
                    itemID: item.itemID, expectedRevisionID: item.revisionID,
                    operationID: "cancel-original", filename: "fixture.png", mediaType: "image/png",
                    byteCount: Int64(original.count),
                    sha256: AuthorityRecordCodec.sha256(original)))
            let uploadID = try XCTUnwrap(upload.uploadID)
            _ = try store.appendAttachment(uploadID: uploadID, offset: 0, data: original)
            let attached = try store.finishAttachment(uploadID: uploadID).revision
            guard
                case .prepared(let snapshot) = try store.prepareAttachmentDocument(
                    itemID: item.itemID,
                    expectedRevisionID: attached.revisionID, attachmentID: upload.attachment.attachmentID,
                    operationID: "cancel-document", identity: .init())
            else { throw TractandaError("fixture", "Expected document preparation") }
            let page = try AttachmentDocumentPage(
                pageNumber: 1,
                geometry: DocumentPageGeometry(
                    sourceWidth: 512, sourceHeight: 256, sourceUnit: "pixel",
                    displayWidth: 512, displayHeight: 256, canvasWidth: 2048, canvasHeight: 1024,
                    contentLeft: 0, contentTop: 0, contentWidth: 2048, contentHeight: 1024),
                rasterSHA256: String(repeating: "b", count: 64),
                parsed: DoclingDocTagsParser.parse(
                    Data("<doctag><text>cancelpageneedle</text></doctag>".utf8)),
                generatedTokens: 16, stopReason: "stop")
            _ = try store.finishAttachmentDocument(snapshot, pages: [page])
        }
        func originals() throws -> [String: String] {
            var values: [String: String] = [:]
            for subtree in ["items", "attachments/payloads", "documents/content"] {
                if let entries = FileManager.default.enumerator(
                    at: storeRoot.appendingPathComponent(subtree), includingPropertiesForKeys: nil)
                {
                    for case let url as URL in entries where (try FileMetadata.read(at: url)).type == .regular
                    {
                        values[url.standardizedFileURL.resolvingSymlinksInPath().path] =
                            AuthorityRecordCodec.sha256(try Data(contentsOf: url))
                    }
                }
            }
            return values
        }
        let daemon = try await SharedDaemon.start(configuration: config)
        let gate = Gate()
        let pause = DispatchSemaphore(value: 0)
        let once = Flags()
        var task: Task<StoreRebuildStatus, Error>?
        do {
            let before = try originals()
            let index = storeRoot.appendingPathComponent("index/items.sqlite")
            let inode = try FileMetadata.read(at: index).inode
            task = Task.detached {
                do {
                    let status = try DocumentContentFiles.observeReadsForTesting(
                        root: storeRoot,
                        observation: { path, _ in
                            if path.contains("pages"), path.last == "1.json", once.first() {
                                Task { await gate.pause() }
                                pause.wait()
                            }
                        },
                        body: {
                            let client = ItemClient(socketPath: config.socketPath)
                            var status = try client.beginStoreRebuild(operationID: "cancel-page-read")
                            while !status.isTerminal {
                                Thread.sleep(forTimeInterval: 0.02)
                                status = try client.storeRebuildStatus(jobID: status.jobID)
                            }
                            return status
                        })
                    await gate.complete()
                    return status
                } catch {
                    await gate.complete()
                    throw error
                }
            }
            let entered = await gate.waitForEntry()
            XCTAssertTrue(entered)
            let active = try await Task.detached {
                try ItemClient(socketPath: config.socketPath).storeRebuildStatus()
            }.value
            _ = try await Task.detached {
                try ItemClient(socketPath: config.socketPath).cancelStoreRebuild(jobID: active.jobID)
            }.value
            pause.signal()
            await gate.release()
            let cancelled = try await XCTUnwrap(task).value
            XCTAssertEqual(cancelled.state, "cancelled")
            XCTAssertFalse(cancelled.indexTrusted)
            XCTAssertTrue(cancelled.requiresRecovery)
            XCTAssertEqual(try FileMetadata.read(at: index).inode, inode)
            XCTAssertEqual(try originals(), before)
            XCTAssertFalse(
                try FileManager.default.contentsOfDirectory(
                    atPath: storeRoot.appendingPathComponent("index").path
                ).contains { $0.hasPrefix("personal-rebuild-") })
            await daemon.close()
            let reopened = try await SharedDaemon.start(configuration: config)
            do {
                let result = try object(
                    await call(config.socketPath, "TractandaItem/query", ["text": "cancelpageneedle"]))
                XCTAssertEqual(result["total"] as? Int, 1)
                await reopened.close()
            } catch {
                await reopened.close()
                throw error
            }
        } catch {
            pause.signal()
            await gate.release()
            if let task { _ = try? await task.value }
            await daemon.close()
            throw error
        }
    }
}
