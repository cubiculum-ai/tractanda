import Crypto
import TractandaClient
import XCTest

@testable import TractandaCore

final class StoreRebuildTests: XCTestCase, @unchecked Sendable {
    private actor Gate {
        var entered = false
        var released = false
        func wait() async throws {
            entered = true
            while !released { try await Task.sleep(for: .milliseconds(5)) }
        }
        func awaitEntry() async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !entered {
                guard ContinuousClock.now < deadline else {
                    throw TractandaError("testTimeout", "Rebuild did not enter")
                }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        func release() { released = true }
    }
    private final class Accounts: AccountDirectory, @unchecked Sendable {
        let admin: UInt32 = 61996
        let reader: UInt32 = 61997
        private let lock = NSLock()
        private var admitted = true
        func revoke() {
            lock.lock()
            admitted = false
            lock.unlock()
        }
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            guard [getuid(), admin, reader].contains(uid) else {
                throw TractandaError("unresolvedPrincipal", "Unknown test user")
            }
            lock.lock()
            let enabled = admitted
            lock.unlock()
            return AccountIdentity(
                uid: uid, name: uid == admin ? "admin" : "reader", primaryGroupName: "staff",
                groupIDs: uid == getuid() || (uid == admin && enabled) ? [71996] : [71997])
        }
        func user(named name: String) throws -> AccountIdentity {
            try user(forUID: name == "admin" ? admin : reader)
        }
        func groupID(named name: String) throws -> UInt32 {
            guard ["admins", "staff"].contains(name) else {
                throw TractandaError("unresolvedPrincipal", "Unknown test group")
            }
            return name == "admins" ? 71996 : 71997
        }
    }
    private func root() throws -> URL {
        // <64KiB estimated complete fixture, well below the 16MiB allocation cap.
        try AttachmentFixtureCapacity.requireFree()
        return FileManager.default.temporaryDirectory.appendingPathComponent("rebuild-" + Identifier.make())
    }
    private func request(_ root: URL, _ method: String, _ args: [String: String] = [:]) throws -> Data {
        try nativeFixtureRequest(
            method: method, arguments: args, accountID: nativeFixtureAccountID(root), callID: "r")
    }
    private func body(_ data: Data) throws -> (String, [String: Any]) {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let call = try XCTUnwrap((object["methodResponses"] as? [[Any]])?.first)
        return (try XCTUnwrap(call[0] as? String), try XCTUnwrap(call[1] as? [String: Any]))
    }
    private func status(_ data: Data) throws -> StoreRebuildStatus {
        let (method, args) = try body(data)
        guard method != "error" else {
            throw TractandaError(args["type"] as? String ?? "test", "Rebuild response failed")
        }
        return try JSON.decode(StoreRebuildStatus.self, JSONSerialization.data(withJSONObject: args))
    }
    private func finished(_ coordinator: ServiceCoordinator, root: URL, uid: UInt32) async throws
        -> StoreRebuildStatus
    {
        for _ in 0..<300 {
            let value = try status(
                await coordinator.handle(request(root, "TractandaStore/rebuildStatus"), forUID: uid))
            if value.isTerminal { return value }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TractandaError("testTimeout", "Rebuild did not terminate")
    }
    func testAdmissionDisconnectRetryFreshAdministratorStatusAndCancel() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = Accounts()
        _ = try ItemStore.initializeFresh(
            root: root, accounts: accounts,
            initialAccessConfiguration: .object([
                "profile": .text(AccessConfiguration.profile),
                "administration": .text("system"), "administratorGroup": .text("admins"),
                "groups": .list([.text("staff")]),
            ]))
        do {
            _ = try ItemStore(
                root: root, accounts: accounts,
                revisionProjectionEnabled: true, authorityIntakeEnabled: true)
        }
        let coordinator = try await ServiceCoordinator(opening: root, makeAccountDirectory: { accounts })
        let gate = Gate()
        await coordinator.setRebuildHookForTesting { try await gate.wait() }
        let begin = try request(root, "TractandaStore/rebuild", ["operationID": "intent"])
        let started = try status(await coordinator.handle(begin, forUID: accounts.admin))
        XCTAssertFalse(started.isTerminal)
        try await gate.awaitEntry()
        let repeated = try status(await coordinator.handle(begin, forUID: accounts.admin))
        XCTAssertEqual(repeated.jobID, started.jobID)
        do {
            _ = try await coordinator.handle(request(root, "TractandaStore/info"), forUID: accounts.admin)
            XCTFail("Ordinary requests must be busy during exclusive rebuild")
        } catch { XCTAssertEqual((error as? TractandaError)?.code, "serviceBusy") }
        let denied = try body(
            await coordinator.handle(request(root, "TractandaStore/rebuildStatus"), forUID: accounts.reader))
        XCTAssertEqual(denied.0, "error")
        XCTAssertNil(denied.1["jobID"])
        accounts.revoke()
        let revoked = try body(
            await coordinator.handle(request(root, "TractandaStore/rebuildStatus"), forUID: accounts.admin))
        XCTAssertEqual(revoked.1["type"] as? String, "forbidden")
        XCTAssertNil(revoked.1["phase"])
        let stopping = try status(
            await coordinator.handle(
                request(root, "TractandaStore/rebuildCancel", ["jobID": started.jobID]), forUID: 0))
        XCTAssertEqual(stopping.state, "stopping")
        await gate.release()
        let final = try await finished(coordinator, root: root, uid: 0)
        XCTAssertEqual(final.state, "cancelled")
        XCTAssertTrue(
            final.indexTrusted, "Cancellation before dirty rebuild preserves the prior trusted index")
        XCTAssertFalse(final.requiresRecovery)
        await coordinator.close()
    }
    func testCancelAfterVerifiedRecordLeavesDirtyIndexAndStartupRestreams() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ItemStore.initializeFresh(root: root)
        do {
            let store = try ItemStore(
                root: root, revisionProjectionEnabled: true, authorityIntakeEnabled: true)
            _ = try store.commit(
                CommitRequest(classID: "Item", changes: ["subject": .text("saved")], operationID: "item"))
        }
        let coordinator = try await ServiceCoordinator(opening: root)
        let entered = expectation(description: "Record verified during exclusive rebuild")
        let release = DispatchSemaphore(value: 0)
        let once = NSLock()
        nonisolated(unsafe) var didEnter = false
        try await coordinator.setRebuildRecordHookForTesting {
            once.lock()
            let first = !didEnter
            didEnter = true
            once.unlock()
            if first {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 5)
            }
        }
        let started = try status(
            await coordinator.handle(
                request(root, "TractandaStore/rebuild", ["operationID": "dirty"]), forUID: getuid()))
        await fulfillment(of: [entered], timeout: 3)
        let progress = try status(
            await coordinator.handle(request(root, "TractandaStore/rebuildStatus"), forUID: getuid()))
        XCTAssertGreaterThan(progress.recordsVerified, 0)
        XCTAssertFalse(progress.indexTrusted)
        _ = try await coordinator.handle(
            request(root, "TractandaStore/rebuildCancel", ["jobID": started.jobID]), forUID: getuid())
        release.signal()
        let final = try await finished(coordinator, root: root, uid: getuid())
        XCTAssertEqual(final.state, "cancelled")
        XCTAssertTrue(final.requiresRecovery)
        XCTAssertFalse(final.indexTrusted)
        XCTAssertTrue(StoreCheckpoint.isDirty(root: root))
        await coordinator.close()
        do {
            let reopened = try ItemStore.openInitialized(root: root)
            XCTAssertTrue(reopened.isCanonicalTrusted)
            XCTAssertFalse(StoreCheckpoint.isDirty(root: root))
        }
        let restarted = try await ServiceCoordinator(opening: root)
        let saved = try status(
            await restarted.handle(request(root, "TractandaStore/rebuildStatus"), forUID: getuid()))
        XCTAssertEqual(
            saved.state, "cancelled", "Terminal cancellation is durable, not a resumed SQLite cursor")
        await restarted.close()
    }
    func testRebuildQuiescesAcceptedCopyAndOriginalVerificationProducers() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        var source: Revision!
        var attachment: AttachmentDescriptor!
        _ = try ItemStore.initializeFresh(root: root)
        do {
            let store = try ItemStore(
                root: root, revisionProjectionEnabled: true, authorityIntakeEnabled: true)
            let base = try store.commit(CommitRequest(classID: "Item", operationID: "item")).revision
            let bytes = Data("tiny original".utf8)
            let upload = try store.beginAttachment(
                AttachmentUploadRequest(
                    itemID: base.itemID,
                    expectedRevisionID: base.revisionID, operationID: "original", filename: "tiny.txt",
                    mediaType: "text/plain", byteCount: Int64(bytes.count),
                    sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()))
            _ = try store.appendAttachment(uploadID: XCTUnwrap(upload.uploadID), offset: 0, data: bytes)
            source = try store.finishAttachment(uploadID: XCTUnwrap(upload.uploadID)).revision
            attachment = upload.attachment
        }
        let coordinator = try await ServiceCoordinator(opening: root)
        let copies = Gate()
        let originals = Gate()
        await coordinator.setAttachmentCopyHookForTesting { try await copies.wait() }
        await coordinator.setAttachmentIntegrityHookForTesting { try await originals.wait() }
        let copy = CommitRequest(
            action: .copy, itemID: source.itemID,
            expectedRevisionID: source.revisionID, operationID: "copy")
        let args = try JSONSerialization.jsonObject(with: JSON.encode(copy))
        let copyRequest = try nativeFixtureEnvelope(
            calls: [["TractandaItem/commit", args, "copy"]], accountID: nativeFixtureAccountID(root))
        let first = try body(await coordinator.handle(copyRequest, forUID: getuid()))
        XCTAssertEqual(first.1["type"] as? String, "attachmentCopyPending")
        try await copies.awaitEntry()
        let read = try nativeFixtureEnvelope(
            calls: [
                [
                    "TractandaAttachment/content",
                    [
                        "itemID": source.itemID,
                        "attachmentID": attachment.attachmentID, "offset": 0, "limit": 1,
                    ], "read",
                ]
            ], accountID: nativeFixtureAccountID(root))
        let pending = try body(await coordinator.handle(read, forUID: getuid()))
        XCTAssertEqual(pending.1["type"] as? String, "attachmentVerifying")
        try await originals.awaitEntry()
        _ = try await coordinator.handle(
            request(root, "TractandaStore/rebuild", ["operationID": "quiesce"]), forUID: getuid())
        let rebuilt = try await finished(coordinator, root: root, uid: getuid())
        XCTAssertEqual(rebuilt.state, "completed")
        XCTAssertTrue(rebuilt.indexTrusted)
        await coordinator.setAttachmentCopyHookForTesting(nil)
        await coordinator.setAttachmentIntegrityHookForTesting(nil)
        // Retrying preserved intent after the producer drain must complete a new independent copy.
        var copied = false
        for _ in 0..<100 {
            let response = try body(await coordinator.handle(copyRequest, forUID: getuid()))
            if response.0 == "TractandaItem/commit" {
                copied = true
                break
            }
            XCTAssertEqual(response.1["type"] as? String, "attachmentCopyPending")
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(copied)
        await coordinator.close()
    }
    func testDurabilityEntriesAdvanceBeyondNoProgressInterval() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        _ = try store.commit(CommitRequest(classID: "Item", operationID: "item"))
        let journal = RebuildJournal(root: root, ownerUID: getuid())
        let initial = StoreRebuildStatus(
            jobID: try UUID.makeVersion1().uuidString.lowercased(),
            operationID: "sync-progress", updatedAt: Timestamp.now(), noProgressTimeoutSeconds: 0.2)
        let control = try RebuildControl(status: initial, journal: journal)
        store.afterCanonicalSyncEntryForTesting = { Thread.sleep(forTimeInterval: 0.03) }
        let started = ProcessInfo.processInfo.systemUptime
        try store.rebuildIndex(control: control)
        XCTAssertGreaterThan(ProcessInfo.processInfo.systemUptime - started, 0.2)
        XCTAssertGreaterThan(control.status.durabilityEntriesChecked, 5)
        XCTAssertTrue(store.isCanonicalTrusted)
    }
    func testSessionAuthorizationStatusAndCancellationBypassOccupiedQueue() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ItemStore.initializeFresh(root: root)
        do {
            let store = try ItemStore(
                root: root, revisionProjectionEnabled: true, authorityIntakeEnabled: true)
            _ = try store.commit(CommitRequest(classID: "Item", operationID: "item"))
        }
        let coordinator = try await ServiceCoordinator(opening: root)
        let sessions = SessionAuthority(coordinator: coordinator)
        let session = try await sessions.issue(forUID: getuid())
        let entered = expectation(description: "Canonical fsync holds Store queue")
        let released = DispatchSemaphore(value: 0)
        let lock = NSLock()
        nonisolated(unsafe) var once = false
        try await coordinator.setCanonicalSyncHookForTesting {
            lock.lock()
            let first = !once
            once = true
            lock.unlock()
            if first {
                entered.fulfill()
                _ = released.wait(timeout: .now() + 5)
            }
        }
        let started = try status(
            await coordinator.handle(
                request(root, "TractandaStore/rebuild", ["operationID": "http-auth"]), forUID: getuid()))
        await fulfillment(of: [entered], timeout: 3)
        let responded = expectation(description: "HTTP session dispatch bypasses occupied Store queue")
        let authenticated = Task {
            let result = try await sessions.dispatch(
                request(root, "TractandaStore/rebuildStatus"), token: session.token)
            responded.fulfill()
            return try status(result)
        }
        await fulfillment(of: [responded], timeout: 1)
        let current = try await authenticated.value
        XCTAssertGreaterThan(current.durabilityEntriesChecked, 0)
        let cancelResponded = expectation(description: "HTTP session cancel is available")
        let cancelling = Task {
            let result = try await sessions.dispatch(
                request(root, "TractandaStore/rebuildCancel", ["jobID": started.jobID]), token: session.token)
            cancelResponded.fulfill()
            return try status(result)
        }
        await fulfillment(of: [cancelResponded], timeout: 1)
        let cancelled = try await cancelling.value
        XCTAssertEqual(cancelled.state, "stopping")
        released.signal()
        let final = try await finished(coordinator, root: root, uid: getuid())
        XCTAssertEqual(final.state, "cancelled")
        XCTAssertEqual(final.durabilityEntriesChecked, 1, "Cancel must stop before the next separate fsync")
        await sessions.close()
        await coordinator.close()
    }
    func testNoTotalDeadlineMeaningfulProgressAndInterruptedJournalRecovery() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        do { _ = try ItemStore(root: root) }
        let journal = RebuildJournal(root: root, ownerUID: getuid())
        let status = StoreRebuildStatus(
            jobID: try UUID.makeVersion1().uuidString.lowercased(), operationID: "progress",
            updatedAt: Timestamp.now(), noProgressTimeoutSeconds: 0.08)
        let control = try RebuildControl(status: status, journal: journal)
        for _ in 0..<8 {
            Thread.sleep(forTimeInterval: 0.02)
            try control.pulse(records: 1)
        }
        XCTAssertEqual(
            control.status.recordsVerified, 8, "Total duration may exceed the no-progress interval")
        Thread.sleep(forTimeInterval: 0.04)
        try control.pulse()  // An unchanged heartbeat is not meaningful progress.
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertThrowsError(try control.check()) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "rebuildNoProgress")
        }
        try journal.save(status)
        let restored = try XCTUnwrap(journal.recoverInterrupted(indexTrusted: true))
        XCTAssertEqual(restored.state, "interruptedRecovered")
        XCTAssertEqual(restored.phase, "startupRecoveryCompleted")
        XCTAssertFalse(restored.requiresRecovery)
    }

    func testNativeCancellationDuringGraphWorkSurvivesGCDBoundary() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ItemStore.initializeFresh(root: root)
        do {
            let store = try ItemStore(
                root: root, revisionProjectionEnabled: true, authorityIntakeEnabled: true)
            _ = try store.commit(CommitRequest(classID: "Item", operationID: "graph-item"))
        }
        let coordinator = try await ServiceCoordinator(opening: root)
        let entered = expectation(description: "GCD graph progress is executing")
        let release = DispatchSemaphore(value: 0)
        let once = NSLock()
        nonisolated(unsafe) var didEnter = false
        try await coordinator.setRebuildGraphProgressHookForTesting {
            once.lock()
            let first = !didEnter
            didEnter = true
            once.unlock()
            if first {
                XCTAssertFalse(
                    Task.isCancelled, "Native cancellation is explicit control, not GCD Task state")
                entered.fulfill()
                _ = release.wait(timeout: .now() + 5)
            }
        }
        let started = try status(
            await coordinator.handle(
                request(root, "TractandaStore/rebuild", ["operationID": "graph-cancel"]), forUID: getuid()))
        await fulfillment(of: [entered], timeout: 3)
        let progress = try status(
            await coordinator.handle(request(root, "TractandaStore/rebuildStatus"), forUID: getuid()))
        XCTAssertEqual(progress.phase, "validatingRevisionGraph")
        _ = try await coordinator.handle(
            request(root, "TractandaStore/rebuildCancel", ["jobID": started.jobID]), forUID: getuid())
        release.signal()
        let final = try await finished(coordinator, root: root, uid: getuid())
        XCTAssertEqual(final.state, "cancelled")
        XCTAssertTrue(final.requiresRecovery)
        await coordinator.close()
        let recovered = try ItemStore.openInitialized(root: root)
        XCTAssertTrue(recovered.isCanonicalTrusted)
    }

    func testGraphWorkAdvancesLivenessWithoutFakingProjectionCounters() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        do { _ = try ItemStore(root: root) }
        let initial = StoreRebuildStatus(
            jobID: try UUID.makeVersion1().uuidString.lowercased(), operationID: "graph-progress",
            updatedAt: Timestamp.now(), noProgressTimeoutSeconds: 0.08)
        let control = try RebuildControl(
            status: initial, journal: RebuildJournal(root: root, ownerUID: getuid()))
        try control.pulse(phase: "validatingRevisionGraph")
        for _ in 0..<8 {
            Thread.sleep(forTimeInterval: 0.02)
            try control.graphProgress()
        }
        XCTAssertEqual(control.status.itemsProjected, 0)
        XCTAssertEqual(control.status.recordsVerified, 0)
        Thread.sleep(forTimeInterval: 0.10)
        XCTAssertThrowsError(try control.graphProgress()) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "rebuildNoProgress")
        }
    }
}
