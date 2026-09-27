import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class ServiceCoordinatorTests: XCTestCase {
    private final class Accounts: AccountDirectory, @unchecked Sendable {
        let service = UInt32(getuid())
        let alice: UInt32 = 51_001
        let bob: UInt32 = 51_002
        let administrator: UInt32 = 51_003
        var users: [UInt32: AccountIdentity]
        var beforeLookup: (@Sendable () -> Void)?
        var groups = ["staff": UInt32(71_001), "operators": UInt32(71_002), "service": UInt32(71_003)]

        init() {
            users = [
                service: AccountIdentity(
                    uid: service, name: "service", primaryGroupName: "service", groupIDs: [71_003]),
                alice: AccountIdentity(
                    uid: alice, name: "alice", primaryGroupName: "staff", groupIDs: [71_001]),
                bob: AccountIdentity(uid: bob, name: "bob", primaryGroupName: "service", groupIDs: [71_003]),
                administrator: AccountIdentity(
                    uid: administrator, name: "operator", primaryGroupName: "operators", groupIDs: [71_002]),
            ]
        }
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            beforeLookup?()
            guard let account = users[uid] else {
                throw TractandaError("unresolvedPrincipal", "Unknown user")
            }
            return account
        }
        func user(named name: String) throws -> AccountIdentity {
            guard let account = users.values.first(where: { $0.name == name }) else {
                throw TractandaError("unresolvedPrincipal", "Unknown user")
            }
            return account
        }
        func groupID(named name: String) throws -> UInt32 {
            guard let group = groups[name] else {
                throw TractandaError("unresolvedPrincipal", "Unknown group")
            }
            return group
        }
    }

    private func systemConfiguration(
        administratorGroup: String = "operators", legacyUsers: [String: ItemValue] = [:]
    ) -> ItemValue {
        .object([
            "profile": .text(AccessConfiguration.profile),
            "groups": .list([.text("staff")]),
            "administration": .text("system"),
            "administratorGroup": .text(administratorGroup),
            "legacyUsers": .object(legacyUsers),
        ])
    }

    private func fixture(_ body: (URL, Accounts) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tractanda-coordinator-\(Identifier.make())")
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root, Accounts())
    }

    private func guardBoundedFixture(_ root: URL, nextItems: Int) throws {
        let gib = UInt64(1024 * 1024 * 1024)
        let cap = gib
        let reserve = 10 * gib
        let perItem = UInt64(128 * 1024)
        let nextEstimate = UInt64(nextItems) * perItem
        var status = statvfs()
        guard root.path.withCString({ statvfs($0, &status) }) == 0 else {
            throw TractandaError("insufficientDisk", "Cannot determine genuine fixture free capacity.")
        }
        let (available, overflow) = UInt64(status.f_bavail)
            .multipliedReportingOverflow(by: UInt64(status.f_frsize))
        guard !overflow, available >= reserve + nextEstimate else {
            throw TractandaError("insufficientDisk", "Fixture would cross the available-space reserve.")
        }
        var actual: UInt64 = 0
        if let entries = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey, .fileSizeKey,
            ])
        {
            for case let url as URL in entries {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if values.isRegularFile == true { actual += UInt64(values.fileSize ?? 0) }
            }
        }
        guard actual <= cap, nextEstimate <= cap - actual else {
            throw TractandaError("insufficientDisk", "Fixture would exceed its 1 GiB cap.")
        }
    }

    private func assertCode(
        _ code: String, _ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("Expected \(code)", file: file, line: line)
        } catch {
            XCTAssertEqual((error as? TractandaError)?.code, code, "\(error)", file: file, line: line)
        }
    }

    private func legacyCopy(
        _ revision: Revision, actorUID: UInt32, operationID: String, into root: URL
    ) throws {
        var fields = revision.fields
        fields["actor"] = .text("uid:\(actorUID)")
        fields["operationID"] = .text(operationID)
        let copied = try Revision(fields: fields)
        let items = root.appendingPathComponent("items")
        let folder = items.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for directory in [root, items, folder] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        let path = folder.appendingPathComponent(copied.revisionID + ".tractanda")
        try RecordCodec.encode(copied).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    func testSystemAdministrationRefreshesAdmissionAndNeverUsesServiceUID() async throws {
        try await fixture { root, accounts in
            var seed: ItemStore? = try ItemStore(root: root, accounts: accounts)
            _ = try seed!.configureAccess(systemConfiguration(), operationID: "system-policy")
            let created = try seed!.withAccess(forUID: accounts.alice) {
                try seed!.commit(
                    CommitRequest(
                        classID: "Item", changes: ["subject": .text("Alice note")],
                        operationID: "alice-create")
                ).revision
            }
            XCTAssertEqual(created.fields["permissions"]?.map?["owner"]?.string, "alice")
            XCTAssertEqual(created.fields["permissions"]?.map?["group"]?.string, "staff")
            seed = nil

            let coordinator = try await ServiceCoordinator(opening: root, makeAccountDirectory: { accounts })
            let aliceIdentity = try await coordinator.accountIdentity(forUID: accounts.alice)
            let administratorIdentity = try await coordinator.accountIdentity(forUID: accounts.administrator)
            XCTAssertEqual(aliceIdentity.name, "alice")
            XCTAssertEqual(administratorIdentity.name, "operator")
            await assertCode("forbidden") {
                _ = try await coordinator.accountIdentity(forUID: accounts.service)
            }
            await assertCode("forbidden") { _ = try await coordinator.accountIdentity(forUID: accounts.bob) }

            accounts.users[accounts.alice] = AccountIdentity(
                uid: accounts.alice, name: "alice", primaryGroupName: "staff", groupIDs: [71_003])
            await assertCode("forbidden") {
                _ = try await coordinator.accountIdentity(forUID: accounts.alice)
            }
            await coordinator.close()
            accounts.groups.removeValue(forKey: "operators")
            let repair = try ItemStore(root: root, accounts: accounts)
            try repair.withAccess(forUID: 0) {
                _ = try repair.configureAccess(
                    systemConfiguration(administratorGroup: "staff"), operationID: "root-repair")
            }
        }
    }

    func testCoordinatorSerializesDistinctPrincipalsAndReleasesWriterOnClose() async throws {
        try await fixture { root, accounts in
            var seed: ItemStore? = try ItemStore(root: root, accounts: accounts)
            _ = try seed!.configureAccess(systemConfiguration(), operationID: "system-policy")
            seed = nil
            let coordinator = try await ServiceCoordinator(opening: root, makeAccountDirectory: { accounts })
            async let alice = coordinator.accountIdentity(forUID: accounts.alice)
            async let administrator = coordinator.accountIdentity(forUID: accounts.administrator)
            let aliceIdentity = try await alice
            let administratorIdentity = try await administrator
            XCTAssertEqual(aliceIdentity.name, "alice")
            XCTAssertEqual(administratorIdentity.name, "operator")
            XCTAssertThrowsError(try ItemStore(root: root, accounts: accounts))
            await coordinator.close()
            let reopened = try ItemStore(root: root, accounts: accounts)
            _ = reopened
            await assertCode("serviceClosed") {
                _ = try await coordinator.accountIdentity(forUID: accounts.alice)
            }
        }
    }

    func testLegacyReceiptRequiresExplicitNamedMappingAfterServiceUIDChanges() async throws {
        try await fixture { root, accounts in
            let store = try ItemStore(root: root, accounts: accounts)
            let request = CommitRequest(
                classID: "Item",
                changes: [
                    "subject": .text("Migrated receipt"),
                    "permissions": .object([
                        "profile": .text(ItemPermissions.profile), "owner": .text("alice"),
                        "group": .text("staff"), "mode": .integer(0o600), "acl": .object([:]),
                    ]),
                ], operationID: "old-service-receipt")
            let original = try store.commit(request).revision
            _ = try store.configureAccess(
                systemConfiguration(legacyUsers: ["uid:\(accounts.service)": .text("alice")]),
                operationID: "system-policy")
            try store.withAccess(forUID: accounts.alice) {
                let replay = try store.commit(request)
                XCTAssertTrue(replay.wasReplayed)
                XCTAssertEqual(replay.revision.revisionID, original.revisionID)
            }
            try store.withAccess(forUID: accounts.administrator) {
                let differentPrincipal = try store.commit(request)
                XCTAssertFalse(differentPrincipal.wasReplayed)
                XCTAssertNotEqual(differentPrincipal.revision.revisionID, original.revisionID)
            }
        }
    }

    func testSeveralLegacyLabelsCanMapToOneUserAndReceiptCollisionsFailClosed() async throws {
        try await fixture { root, accounts in
            XCTAssertThrowsError(
                try AccessConfiguration(
                    systemConfiguration(legacyUsers: ["uid:0\(accounts.alice)": .text("alice")]))
            )
            let sourceRoot = root.appendingPathComponent("source")
            var source: ItemStore? = try ItemStore(root: sourceRoot, accounts: accounts)
            func request(_ operationID: String) -> CommitRequest {
                CommitRequest(
                    classID: "Item",
                    changes: [
                        "subject": .text(operationID),
                        "permissions": .object([
                            "profile": .text(ItemPermissions.profile), "owner": .text("alice"),
                            "group": .text("staff"), "mode": .integer(0o600), "acl": .object([:]),
                        ]),
                    ], operationID: operationID)
            }
            let first = try source!.commit(request("first")).revision
            let second = try source!.commit(request("second")).revision
            let collisionA = try source!.commit(request("collision-a")).revision
            let collisionB = try source!.commit(request("collision-b")).revision
            source = nil

            let migrated = root.appendingPathComponent("migrated")
            try legacyCopy(first, actorUID: accounts.alice, operationID: "first", into: migrated)
            try legacyCopy(second, actorUID: accounts.bob, operationID: "second", into: migrated)
            try legacyCopy(collisionA, actorUID: accounts.alice, operationID: "collision", into: migrated)
            try legacyCopy(collisionB, actorUID: accounts.bob, operationID: "collision", into: migrated)
            let store = try ItemStore(root: migrated, accounts: accounts)
            _ = try store.configureAccess(
                systemConfiguration(legacyUsers: [
                    "uid:\(accounts.alice)": .text("alice"), "uid:\(accounts.bob)": .text("alice"),
                ]), operationID: "system-policy")
            try store.withAccess(forUID: accounts.alice) {
                XCTAssertTrue(try store.commit(request("first")).wasReplayed)
                XCTAssertTrue(try store.commit(request("second")).wasReplayed)
                XCTAssertThrowsError(try store.commit(request("collision"))) {
                    XCTAssertEqual(($0 as? TractandaError)?.code, "operationMismatch")
                }
            }
        }
    }

    func testCloseDrainsAnAcceptedRequestBeforeReleasingTheWriter() async throws {
        try await fixture { root, accounts in
            let coordinator = try await ServiceCoordinator(opening: root, makeAccountDirectory: { accounts })
            let entered = expectation(description: "Accepted work reached the serialized store queue")
            let release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            accounts.beforeLookup = {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 10)
            }
            let request = Task { try await coordinator.accountIdentity(forUID: accounts.service) }
            await fulfillment(of: [entered], timeout: 5)
            // Task.yield is not admission: explicitly observe accepted work before racing close.
            let closing = Task { await coordinator.close() }
            XCTAssertThrowsError(try ItemStore(root: root, accounts: accounts))
            release.signal()
            let identity = try await request.value
            XCTAssertEqual(identity.name, "service")
            await closing.value
            accounts.beforeLookup = nil
            let reopened = try ItemStore(root: root, accounts: accounts)
            _ = reopened
            await assertCode("serviceClosed") {
                _ = try await coordinator.accountIdentity(forUID: accounts.service)
            }
        }
    }

    private actor PreparedReadGate {
        private var arrivals = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func pause() async {
            arrivals += 1
            await withCheckedContinuation { waiters.append($0) }
        }

        func count() -> Int { arrivals }

        func release() {
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }

    private func nativeRequest(_ method: String, _ arguments: [String: Any], id: String = "read") throws
        -> Data
    {
        try JSONSerialization.data(withJSONObject: [
            "using": [ItemService.capability], "methodCalls": [[method, arguments, id]],
        ])
    }

    private func nativePage(_ data: Data) throws -> (ids: [String], total: Int) {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let calls = try XCTUnwrap(object["methodResponses"] as? [[Any]])
        let result = try XCTUnwrap(calls.first?[1] as? [String: Any])
        return (try XCTUnwrap(result["ids"] as? [String]), try XCTUnwrap(result["total"] as? Int))
    }

    private func waitForPreparedReads(_ count: Int, gate: PreparedReadGate) async throws {
        for _ in 0..<100 {
            if await gate.count() >= count { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Prepared evaluations did not overlap")
    }

    func testBoundedPreparedQueriesActuallyOverlap() async throws {
        try await fixture { root, accounts in
            var seed: ItemStore? = try ItemStore(root: root, accounts: accounts)
            let first = try seed!.commit(
                CommitRequest(
                    classID: "Item", changes: ["subject": .text("Alpha")], operationID: "parallel-a")
            ).revision
            let second = try seed!.commit(
                CommitRequest(classID: "Item", changes: ["subject": .text("Beta")], operationID: "parallel-b")
            ).revision
            seed = nil
            let coordinator = try await ServiceCoordinator(opening: root, makeAccountDirectory: { accounts })
            let gate = PreparedReadGate()
            await coordinator.setPreparedReadHookForTesting { await gate.pause() }
            let request = try nativeRequest(
                "TractandaItem/query", ["sort": [["property": "subject", "isAscending": true]]])
            async let firstResponse = coordinator.handle(request, forUID: accounts.service)
            async let secondResponse = coordinator.handle(request, forUID: accounts.service)
            try await waitForPreparedReads(2, gate: gate)
            await gate.release()
            let pageA = try nativePage(await firstResponse)
            let pageB = try nativePage(await secondResponse)
            XCTAssertEqual(pageA.ids, [first.itemID, second.itemID])
            XCTAssertEqual(pageB.ids, pageA.ids)
            XCTAssertEqual(pageA.total, 2)
            await coordinator.close()
        }
    }

    func testSelectiveIndexedParallelQueryWorksBeyondFullScanBound() async throws {
        try await fixture { root, accounts in
            var seed: ItemStore? = try ItemStore(root: root, accounts: accounts)
            var target: Revision?
            try guardBoundedFixture(root, nextItems: 513)
            for index in 0..<513 {
                if index.isMultiple(of: 64) {
                    try guardBoundedFixture(root, nextItems: min(64, 513 - index))
                }
                let item = try seed!.commit(
                    CommitRequest(
                        classID: "Item", changes: ["subject": .text("row-\(index)")],
                        operationID: "selective-parallel-\(index)")
                ).revision
                if index == 509 { target = item }
            }
            let selected = try XCTUnwrap(target)
            seed = nil

            let coordinator = try await ServiceCoordinator(opening: root, makeAccountDirectory: { accounts })
            let counter = ReadCounter()
            await coordinator.setPreparedReadHookForTesting { await counter.record() }
            let request = try nativeRequest(
                "TractandaItem/query",
                [
                    "expression": "itemID == \"\(selected.itemID)\"",
                    "sort": [["property": "subject", "isAscending": true]],
                ])
            let page = try nativePage(try await coordinator.handle(request, forUID: accounts.service))
            XCTAssertEqual(page.ids, [selected.itemID])
            XCTAssertEqual(page.total, 1)
            let evaluations = await counter.count()
            XCTAssertEqual(evaluations, 1)
            await coordinator.close()
        }
    }

    func testPreparedQueryRechecksRevokedAccessBeforeDelivery() async throws {
        try await fixture { root, accounts in
            accounts.users[accounts.bob] = AccountIdentity(
                uid: accounts.bob, name: "bob", primaryGroupName: "staff", groupIDs: [71_001])
            let shared: (Int64) -> ItemValue = { mode in
                .object([
                    "profile": .text(ItemPermissions.profile), "owner": .text("alice"),
                    "group": .text("staff"), "mode": .integer(mode), "acl": .object([:]),
                ])
            }
            var seed: ItemStore? = try ItemStore(root: root, accounts: accounts)
            _ = try seed!.configureAccess(systemConfiguration(), operationID: "parallel-policy")
            let item = try seed!.withAccess(forUID: accounts.alice) {
                try seed!.commit(
                    CommitRequest(
                        classID: "Item",
                        changes: ["subject": .text("Shared"), "permissions": shared(0o640)],
                        operationID: "parallel-shared")
                ).revision
            }
            seed = nil
            let coordinator = try await ServiceCoordinator(opening: root, makeAccountDirectory: { accounts })
            let gate = PreparedReadGate()
            await coordinator.setPreparedReadHookForTesting { await gate.pause() }
            let request = try nativeRequest(
                "TractandaItem/query", ["sort": [["property": "subject", "isAscending": true]]])
            let reading = Task { try await coordinator.handle(request, forUID: accounts.bob) }
            try await waitForPreparedReads(1, gate: gate)
            let changes = CommitRequest(
                action: .revise, itemID: item.itemID, expectedRevisionID: item.revisionID,
                changes: ["permissions": shared(0o600)], operationID: "parallel-revoke")
            let arguments = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSON.encode(changes)) as? [String: Any])
            let committed = try await coordinator.handle(
                nativeRequest("TractandaItem/commit", arguments, id: "write"), forUID: accounts.alice)
            XCTAssertTrue(String(decoding: committed, as: UTF8.self).contains("parallel-revoke"))
            await gate.release()
            let page = try nativePage(await reading.value)
            XCTAssertEqual(page.ids, [])
            XCTAssertEqual(page.total, 0)

            let admissionGate = PreparedReadGate()
            await coordinator.setPreparedReadHookForTesting { await admissionGate.pause() }
            let rejected = Task { try await coordinator.handle(request, forUID: accounts.bob) }
            try await waitForPreparedReads(1, gate: admissionGate)
            accounts.users[accounts.bob] = AccountIdentity(
                uid: accounts.bob, name: "bob", primaryGroupName: "service", groupIDs: [71_003])
            await admissionGate.release()
            let rejectedData = try await rejected.value
            let rejectedObject = try XCTUnwrap(
                JSONSerialization.jsonObject(with: rejectedData) as? [String: Any])
            XCTAssertEqual(rejectedObject["code"] as? String, "forbidden")
            await coordinator.close()
        }
    }

    func testPreparedQueryReportsCanonicalDamageAsMethodError() async throws {
        try await fixture { root, accounts in
            var seed: ItemStore? = try ItemStore(root: root, accounts: accounts)
            let item = try seed!.commit(
                CommitRequest(
                    classID: "Item", changes: ["subject": .text("Record")],
                    operationID: "parallel-integrity")
            ).revision
            seed = nil
            let coordinator = try await ServiceCoordinator(opening: root, makeAccountDirectory: { accounts })
            let gate = PreparedReadGate()
            await coordinator.setPreparedReadHookForTesting { await gate.pause() }
            let request = try nativeRequest(
                "TractandaItem/query", ["sort": [["property": "subject", "isAscending": true]]])
            let reading = Task { try await coordinator.handle(request, forUID: accounts.service) }
            try await waitForPreparedReads(1, gate: gate)
            let files =
                FileManager.default.enumerator(
                    at: root.appendingPathComponent("items"), includingPropertiesForKeys: nil)?.allObjects
                as? [URL] ?? []
            let record = try XCTUnwrap(
                files.first {
                    $0.lastPathComponent == item.revisionID + ".tractanda"
                })
            XCTAssertEqual(record.path.withCString { chmod($0, mode_t(0o600)) }, 0)
            let handle = try FileHandle(forWritingTo: record)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data("changed".utf8))
            try handle.close()
            XCTAssertEqual(record.path.withCString { chmod($0, mode_t(0o400)) }, 0)
            await gate.release()
            let response = try await reading.value
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: response) as? [String: Any])
            let calls = try XCTUnwrap(object["methodResponses"] as? [[Any]])
            XCTAssertEqual(calls.first?[0] as? String, "error")
            XCTAssertEqual((calls.first?[1] as? [String: Any])?["type"] as? String, "recoveryError")
            await coordinator.close()
        }
    }

    private actor ReadCounter {
        private var value = 0
        func record() { value += 1 }
        func count() -> Int { value }
    }

    func testOversizedPreparedSnapshotUsesSerialQuery() async throws {
        try await fixture { root, accounts in
            var seed: ItemStore? = try ItemStore(root: root, accounts: accounts)
            let item = try seed!.commit(
                CommitRequest(
                    classID: "Item",
                    changes: [
                        "subject": .text("Large"), "body": .text(String(repeating: "x", count: 1_000_000)),
                    ],
                    operationID: "parallel-large")
            ).revision
            seed = nil
            let coordinator = try await ServiceCoordinator(opening: root, makeAccountDirectory: { accounts })
            let counter = ReadCounter()
            await coordinator.setPreparedReadHookForTesting { await counter.record() }
            let request = try nativeRequest(
                "TractandaItem/query", ["sort": [["property": "subject", "isAscending": true]]])
            let page = try nativePage(try await coordinator.handle(request, forUID: accounts.service))
            XCTAssertEqual(page.ids, [item.itemID])
            let parallelEvaluations = await counter.count()
            XCTAssertEqual(parallelEvaluations, 0)
            await coordinator.close()
        }
    }
}
