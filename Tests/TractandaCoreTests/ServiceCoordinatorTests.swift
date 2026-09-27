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
        guard case .date(let modifiedAt)? = copied.fields["modifiedAt"],
            let date = Timestamp.parse(modifiedAt)
        else { throw TractandaError("invalidDate", "Legacy fixture has no modification timestamp.") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let folder = items.appendingPathComponent(
            String(
                format: "%04d/%02d/%02d/%02d/%02d/%@",
                components.year!, components.month!, components.day!, components.hour!, components.minute!,
                copied.itemID))
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var directory = folder
        while directory.path.hasPrefix(root.path + "/") {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path)
            directory.deleteLastPathComponent()
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

    func testPooledOrdinaryQueriesOverlapAndCursorContinuesOnCurrentState() async throws {
        try await fixture { root, accounts in
            var seed: ItemStore? = try ItemStore(root: root, accounts: accounts)
            for number in 0..<3 {
                _ = try seed?.commit(
                    CommitRequest(
                        classID: "Item", changes: ["subject": .text("pooled-\(number)")],
                        operationID: "pooled-query-\(number)"))
            }
            seed = nil
            let coordinator = try await ServiceCoordinator(
                opening: root, makeAccountDirectory: { accounts })
            let bothLeases = expectation(description: "Two independent read leases are active")
            bothLeases.expectedFulfillmentCount = 2
            let release = DispatchSemaphore(value: 0)
            await coordinator.setPooledReadLeaseHookForTesting {
                bothLeases.fulfill()
                _ = release.wait(timeout: .now() + 10)
            }
            let request = try nativeRequest("TractandaItem/query", ["limit": 2])
            let first = Task { try await coordinator.handle(request, forUID: accounts.service) }
            let second = Task { try await coordinator.handle(request, forUID: accounts.service) }
            await fulfillment(of: [bothLeases], timeout: 5)
            let activeLeases = await coordinator.pooledReadLeaseCountForTesting()
            XCTAssertEqual(activeLeases, 2)
            release.signal()
            release.signal()
            let firstData = try await first.value
            let secondData = try await second.value
            XCTAssertEqual(try nativePage(firstData).total, 3)
            XCTAssertEqual(try nativePage(secondData).ids, try nativePage(firstData).ids)
            await coordinator.setPooledReadLeaseHookForTesting(nil)

            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: firstData) as? [String: Any])
            let calls = try XCTUnwrap(object["methodResponses"] as? [[Any]])
            let result = try XCTUnwrap(calls[0][1] as? [String: Any])
            let cursor = try XCTUnwrap(result["nextCursor"] as? String)
            let next = try await coordinator.handle(
                nativeRequest("TractandaItem/query", ["cursor": cursor, "limit": 2]),
                forUID: accounts.service)
            XCTAssertEqual(try nativePage(next).total, 3)
            XCTAssertEqual(Set(try nativePage(firstData).ids + nativePage(next).ids).count, 3)
            await coordinator.close()
        }
    }

    func testPooledScalarResidualQueriesMatchSerialUnicodeAndInt64Oracle() async throws {
        try await fixture { root, accounts in
            var seed: ItemStore? = try ItemStore(root: root, accounts: accounts)
            _ = try seed!.commit(
                CommitRequest(
                    classID: "Item",
                    changes: ["subject": .text("Café"), "big": .integer(9_007_199_254_740_993)],
                    operationID: "pooled-scalar-a"))
            _ = try seed!.commit(
                CommitRequest(
                    classID: "Item",
                    changes: ["subject": .text("Cafe\u{301}"), "big": .integer(9_007_199_254_740_992)],
                    operationID: "pooled-scalar-b"))
            _ = try seed!.commit(
                CommitRequest(
                    classID: "Item", changes: ["subject": .text("outside")],
                    operationID: "pooled-scalar-c"))
            let expressions = ["subject == \"Café\"", "big == 9007199254740993"]
            let oracle = try expressions.map {
                try Categories.query(store: seed!, expression: $0).map(\.itemID)
            }
            seed = nil
            let coordinator = try await ServiceCoordinator(
                opening: root, makeAccountDirectory: { accounts })
            let streamed = expectation(description: "Both residual queries used pooled leases")
            streamed.expectedFulfillmentCount = 2
            await coordinator.setPooledReadLeaseHookForTesting { streamed.fulfill() }
            for (index, expression) in expressions.enumerated() {
                let response = try await coordinator.handle(
                    nativeRequest("TractandaItem/query", ["expression": expression, "limit": 10]),
                    forUID: accounts.service)
                let page = try nativePage(response)
                XCTAssertEqual(page.ids, oracle[index])
                XCTAssertEqual(page.total, oracle[index].count)
            }
            await fulfillment(of: [streamed], timeout: 5)
            await coordinator.setPooledReadLeaseHookForTesting(nil)
            await coordinator.close()
        }
    }

    func testPooledCategoryRuleQueryMatchesExactManualMembership() async throws {
        try await fixture { root, accounts in
            var seed: ItemStore? = try ItemStore(root: root, accounts: accounts)
            let category = try seed!.commit(
                CommitRequest(
                    classID: "Item",
                    changes: [
                        "selection": .object([
                            "language": .text(SpotlightQuery.profile), "expression": .text("bucket == 1"),
                        ])
                    ], operationID: "pool-category-root")
            ).revision
            _ = try seed!.commit(
                CommitRequest(
                    classID: "Item", changes: ["bucket": .integer(1)],
                    operationID: "pool-category-match"))
            _ = try seed!.commit(
                CommitRequest(
                    classID: "Item",
                    changes: [
                        "bucket": .integer(1),
                        "categoryOverrides": .object([category.itemID: .text("exclude")]),
                    ], operationID: "pool-category-exclude"))
            _ = try seed!.commit(
                CommitRequest(
                    classID: "Item",
                    changes: [
                        "bucket": .integer(0),
                        "categoryOverrides": .object([category.itemID: .text("include")]),
                    ], operationID: "pool-category-include"))
            _ = try seed!.commit(
                CommitRequest(
                    classID: "Item", changes: ["bucket": .integer(0)],
                    operationID: "pool-category-outside"))
            let oracle = try Categories.query(
                store: seed!, categoryPath: [category.itemID]
            ).map(\.itemID)
            seed = nil
            let coordinator = try await ServiceCoordinator(
                opening: root, makeAccountDirectory: { accounts })
            let leased = expectation(description: "Category query used an isolated read lease")
            await coordinator.setPooledReadLeaseHookForTesting { leased.fulfill() }
            let response = try await coordinator.handle(
                nativeRequest(
                    "TractandaItem/query",
                    [
                        "categoryPath": [category.itemID], "limit": 10,
                    ]), forUID: accounts.service)
            let page = try nativePage(response)
            XCTAssertEqual(page.ids, oracle)
            XCTAssertEqual(page.total, oracle.count)
            await fulfillment(of: [leased], timeout: 5)
            await coordinator.setPooledReadLeaseHookForTesting(nil)
            await coordinator.close()
        }
    }

    func testPooledSavedCategoryViewUsesCurrentDefinitionAndExactMembership() async throws {
        try await fixture { root, accounts in
            var seed: ItemStore? = try ItemStore(root: root, accounts: accounts)
            let category = try seed!.commit(
                CommitRequest(
                    classID: "Item",
                    changes: [
                        "selection": .object([
                            "language": .text(SpotlightQuery.profile), "expression": .text("bucket == 1"),
                        ])
                    ], operationID: "pool-view-category")
            ).revision
            _ = try seed!.commit(
                CommitRequest(
                    classID: "Item", changes: ["bucket": .integer(1)],
                    operationID: "pool-view-match"))
            _ = try seed!.commit(
                CommitRequest(
                    classID: "Item", changes: ["bucket": .integer(0)],
                    operationID: "pool-view-outside"))
            let view = try seed!.commit(
                CommitRequest(
                    classID: "Item",
                    changes: [
                        "viewDefinition": .object([
                            "language": .text(SpotlightQuery.profile),
                            "categoryPath": .list([.reference(ItemReference(category.itemID))]),
                        ])
                    ], operationID: "pool-view-definition")
            ).revision
            let oracle = try Categories.savedViewPage(
                store: seed!, id: view.itemID, sectionID: nil, position: 0, limit: 10,
                at: Date(), timeZone: "UTC")
            seed = nil
            let coordinator = try await ServiceCoordinator(
                opening: root, makeAccountDirectory: { accounts })
            let leased = expectation(description: "Saved category view used a read lease")
            await coordinator.setPooledReadLeaseHookForTesting { leased.fulfill() }
            let response = try await coordinator.handle(
                nativeRequest("TractandaItem/query", ["viewID": view.itemID, "limit": 10]),
                forUID: accounts.service)
            XCTAssertEqual(try nativePage(response).ids, oracle.ids)
            XCTAssertEqual(try nativePage(response).total, oracle.total)
            await fulfillment(of: [leased], timeout: 5)
            await coordinator.setPooledReadLeaseHookForTesting(nil)
            await coordinator.close()
        }
    }

    func testPooledGetRechecksCurrentPermissionBeforeDelivery() async throws {
        try await fixture { root, accounts in
            accounts.users[accounts.bob] = AccountIdentity(
                uid: accounts.bob, name: "bob", primaryGroupName: "staff", groupIDs: [71_001])
            let permissions: (Int64) -> ItemValue = { mode in
                .object([
                    "profile": .text(ItemPermissions.profile), "owner": .text("alice"),
                    "group": .text("staff"), "mode": .integer(mode), "acl": .object([:]),
                ])
            }
            var seed: ItemStore? = try ItemStore(root: root, accounts: accounts)
            _ = try seed!.configureAccess(systemConfiguration(), operationID: "pooled-get-policy")
            let item = try seed!.withAccess(forUID: accounts.alice) {
                try seed!.commit(
                    CommitRequest(
                        classID: "Item",
                        changes: ["subject": .text("shared"), "permissions": permissions(0o640)],
                        operationID: "pooled-get-shared")
                ).revision
            }
            seed = nil
            let coordinator = try await ServiceCoordinator(
                opening: root, makeAccountDirectory: { accounts })
            let gate = PreparedReadGate()
            await coordinator.setPooledReadBeforeFinishHookForTesting { await gate.pause() }
            let request = try nativeRequest("TractandaItem/get", ["ids": [item.itemID]])
            let reading = Task { try await coordinator.handle(request, forUID: accounts.bob) }
            try await waitForPreparedReads(1, gate: gate)
            let change = CommitRequest(
                action: .revise, itemID: item.itemID, expectedRevisionID: item.revisionID,
                changes: ["permissions": permissions(0o600)], operationID: "pooled-get-revoke")
            let arguments = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSON.encode(change)) as? [String: Any])
            _ = try await coordinator.handle(
                nativeRequest("TractandaItem/commit", arguments, id: "write"),
                forUID: accounts.alice)
            await gate.release()
            let result = try await reading.value
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
            let calls = try XCTUnwrap(object["methodResponses"] as? [[Any]])
            let payload = try XCTUnwrap(calls[0][1] as? [String: Any])
            XCTAssertTrue((payload["list"] as? [Any])?.isEmpty == true)
            XCTAssertEqual(payload["notFound"] as? [String], [item.itemID])
            await coordinator.setPooledReadBeforeFinishHookForTesting(nil)
            await coordinator.close()
        }
    }

    func testPooledGetAndHistoryOverlapWithExactHistoryPage() async throws {
        try await fixture { root, accounts in
            var seed: ItemStore? = try ItemStore(root: root, accounts: accounts)
            var item = try seed!.commit(
                CommitRequest(
                    classID: "Item", changes: ["subject": .text("first")],
                    operationID: "pooled-history-first")
            ).revision
            let first = item
            item = try seed!.commit(
                CommitRequest(
                    action: .revise, itemID: item.itemID, expectedRevisionID: item.revisionID,
                    changes: ["subject": .text("second")],
                    operationID: "pooled-history-second")
            ).revision
            let second = item
            item = try seed!.commit(
                CommitRequest(
                    action: .revise, itemID: item.itemID, expectedRevisionID: item.revisionID,
                    changes: ["subject": .text("third")],
                    operationID: "pooled-history-third")
            ).revision
            seed = nil
            let coordinator = try await ServiceCoordinator(
                opening: root, makeAccountDirectory: { accounts })
            let bothLeases = expectation(description: "Pooled get and history overlap")
            bothLeases.expectedFulfillmentCount = 2
            let release = DispatchSemaphore(value: 0)
            await coordinator.setPooledReadLeaseHookForTesting {
                bothLeases.fulfill()
                _ = release.wait(timeout: .now() + 10)
            }
            let getRequest = try nativeRequest("TractandaItem/get", ["ids": [item.itemID]])
            let historyRequest = try nativeRequest(
                "TractandaItem/history", ["itemID": item.itemID, "position": 1, "limit": 1])
            let getting = Task { try await coordinator.handle(getRequest, forUID: accounts.service) }
            let listing = Task { try await coordinator.handle(historyRequest, forUID: accounts.service) }
            await fulfillment(of: [bothLeases], timeout: 5)
            let activeLeases = await coordinator.pooledReadLeaseCountForTesting()
            XCTAssertEqual(activeLeases, 2)
            release.signal()
            release.signal()
            let getResponse = try await getting.value
            let historyResponse = try await listing.value
            let getObject = try XCTUnwrap(JSONSerialization.jsonObject(with: getResponse) as? [String: Any])
            let getCall = try XCTUnwrap((getObject["methodResponses"] as? [[Any]])?.first)
            let getPayload = try XCTUnwrap(getCall[1] as? [String: Any])
            let current = try JSON.decode(
                [Revision].self, JSONSerialization.data(withJSONObject: getPayload["list"]!))
            XCTAssertEqual(current.map(\.revisionID), [item.revisionID])
            let historyObject = try XCTUnwrap(
                JSONSerialization.jsonObject(with: historyResponse) as? [String: Any])
            let historyCall = try XCTUnwrap((historyObject["methodResponses"] as? [[Any]])?.first)
            let historyPayload = try XCTUnwrap(historyCall[1] as? [String: Any])
            XCTAssertEqual(historyPayload["total"] as? Int, 3)
            let versions = try JSON.decode(
                [Revision].self, JSONSerialization.data(withJSONObject: historyPayload["list"]!))
            XCTAssertEqual(versions.map(\.revisionID), [second.revisionID])
            XCTAssertNotEqual(first.revisionID, second.revisionID)
            await coordinator.setPooledReadLeaseHookForTesting(nil)
            await coordinator.close()
        }
    }

    func testPooledHistoryRefreshesAfterConcurrentRevisionBeforeDelivery() async throws {
        try await fixture { root, accounts in
            var seed: ItemStore? = try ItemStore(root: root, accounts: accounts)
            let first = try seed!.commit(
                CommitRequest(
                    classID: "Item", changes: ["subject": .text("before")],
                    operationID: "pool-history-concurrent-first")
            ).revision
            seed = nil
            let coordinator = try await ServiceCoordinator(
                opening: root, makeAccountDirectory: { accounts })
            let gate = PreparedReadGate()
            await coordinator.setPooledReadBeforeFinishHookForTesting { await gate.pause() }
            let request = try nativeRequest("TractandaItem/history", ["itemID": first.itemID])
            let reading = Task { try await coordinator.handle(request, forUID: accounts.service) }
            try await waitForPreparedReads(1, gate: gate)
            let change = CommitRequest(
                action: .revise, itemID: first.itemID,
                expectedRevisionID: first.revisionID,
                changes: ["subject": .text("after")],
                operationID: "pool-history-concurrent-second")
            let arguments = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSON.encode(change)) as? [String: Any])
            _ = try await coordinator.handle(
                nativeRequest("TractandaItem/commit", arguments), forUID: accounts.service)
            await gate.release()
            let response = try await reading.value
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
            let call = try XCTUnwrap((object["methodResponses"] as? [[Any]])?.first)
            let payload = try XCTUnwrap(call[1] as? [String: Any])
            XCTAssertEqual(payload["total"] as? Int, 2)
            let revisions = try JSON.decode(
                [Revision].self, JSONSerialization.data(withJSONObject: payload["list"]!))
            XCTAssertEqual(revisions.count, 2)
            XCTAssertEqual(revisions.last?.revisionID, first.revisionID)
            await coordinator.setPooledReadBeforeFinishHookForTesting(nil)
            await coordinator.close()
        }
    }

    func testPooledHistoryAppendAfterSnapshotDoesNotReportDisconnectedChain() async throws {
        try await fixture { root, accounts in
            var seed: ItemStore? = try ItemStore(root: root, accounts: accounts)
            let first = try seed!.commit(
                CommitRequest(
                    classID: "Item", changes: ["subject": .text("before snapshot")],
                    operationID: "pool-history-snapshot-first")
            ).revision
            seed = nil
            let coordinator = try await ServiceCoordinator(
                opening: root, makeAccountDirectory: { accounts })
            let entered = expectation(description: "History captured its short initial WAL snapshot")
            let release = DispatchSemaphore(value: 0)
            await coordinator.setPooledHistoryAfterSnapshotHookForTesting {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 10)
            }
            let request = try nativeRequest("TractandaItem/history", ["itemID": first.itemID])
            let reading = Task { try await coordinator.handle(request, forUID: accounts.service) }
            await fulfillment(of: [entered], timeout: 5)
            let change = CommitRequest(
                action: .revise, itemID: first.itemID,
                expectedRevisionID: first.revisionID,
                changes: ["subject": .text("after snapshot")],
                operationID: "pool-history-snapshot-second")
            let arguments = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSON.encode(change)) as? [String: Any])
            _ = try await coordinator.handle(
                nativeRequest("TractandaItem/commit", arguments), forUID: accounts.service)
            release.signal()
            let response = try await reading.value
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
            let call = try XCTUnwrap((object["methodResponses"] as? [[Any]])?.first)
            XCTAssertEqual(call[0] as? String, "TractandaItem/history")
            let payload = try XCTUnwrap(call[1] as? [String: Any])
            XCTAssertEqual(payload["total"] as? Int, 2)
            await coordinator.setPooledHistoryAfterSnapshotHookForTesting(nil)
            await coordinator.close()
        }
    }

    func testPooledRecordAndHistoryLimitsReturnErrorsWithoutPartialResults() async throws {
        try await fixture { root, accounts in
            var seed: ItemStore? = try ItemStore(root: root, accounts: accounts)
            var item = try seed!.commit(
                CommitRequest(
                    classID: "Item", changes: ["subject": .text("first")],
                    operationID: "pooled-budget-first")
            ).revision
            let secondItem = try seed!.commit(
                CommitRequest(
                    classID: "Item", changes: ["subject": .text("other")],
                    operationID: "pooled-budget-other")
            ).revision
            for number in 0..<2 {
                item = try seed!.commit(
                    CommitRequest(
                        action: .revise, itemID: item.itemID, expectedRevisionID: item.revisionID,
                        changes: ["subject": .text("revision-\(number)")],
                        operationID: "pooled-budget-revise-\(number)")
                ).revision
            }
            let rows = try seed!.exportCatalogueForVerification()
            let currentSizes = rows.filter {
                $0.revisionID == item.revisionID || $0.revisionID == secondItem.revisionID
            }.map(\.size)
            let byteLimit = try XCTUnwrap(currentSizes.max())
            seed = nil
            let coordinator = try await ServiceCoordinator(
                opening: root, makeAccountDirectory: { accounts })
            try await coordinator.setPooledRecordByteLimitForTesting(Int(byteLimit))

            func errorType(_ response: Data) throws -> String? {
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
                let call = try XCTUnwrap((object["methodResponses"] as? [[Any]])?.first)
                XCTAssertEqual(call[0] as? String, "error")
                let payload = try XCTUnwrap(call[1] as? [String: Any])
                XCTAssertNil(payload["list"])
                return payload["type"] as? String
            }
            let get = try await coordinator.handle(
                nativeRequest("TractandaItem/get", ["ids": [item.itemID, secondItem.itemID]]),
                forUID: accounts.service)
            XCTAssertEqual(try errorType(get), "resourceLimit")
            let history = try await coordinator.handle(
                nativeRequest("TractandaItem/history", ["itemID": item.itemID, "limit": 3]),
                forUID: accounts.service)
            XCTAssertEqual(try errorType(history), "resourceLimit")

            try await coordinator.setPooledRecordByteLimitForTesting(nil)
            try await coordinator.setPooledHistoryBatchLimitForTesting(2)
            let overflow = try await coordinator.handle(
                nativeRequest("TractandaItem/history", ["itemID": item.itemID, "limit": 1]),
                forUID: accounts.service)
            let overflowObject = try XCTUnwrap(
                JSONSerialization.jsonObject(with: overflow) as? [String: Any])
            let overflowCall = try XCTUnwrap(
                (overflowObject["methodResponses"] as? [[Any]])?.first)
            let overflowPayload = try XCTUnwrap(overflowCall[1] as? [String: Any])
            XCTAssertEqual(overflowPayload["total"] as? Int, 3)
            XCTAssertEqual((overflowPayload["list"] as? [Any])?.count, 1)
            await coordinator.close()
        }
    }

    func testMixedEnvelopeSerialHistoryCountsPastBatchBoundary() async throws {
        try await fixture { root, accounts in
            var seed: ItemStore? = try ItemStore(root: root, accounts: accounts)
            var item = try seed!.commit(
                CommitRequest(
                    classID: "Item", changes: ["subject": .text("first")],
                    operationID: "mixed-history-first")
            ).revision
            for number in 0..<2 {
                item = try seed!.commit(
                    CommitRequest(
                        action: .revise, itemID: item.itemID, expectedRevisionID: item.revisionID,
                        changes: ["subject": .text("revision-\(number)")],
                        operationID: "mixed-history-revise-\(number)")
                ).revision
            }
            seed = nil
            let coordinator = try await ServiceCoordinator(
                opening: root, makeAccountDirectory: { accounts })
            try await coordinator.setPooledHistoryBatchLimitForTesting(2)
            let request = try JSONSerialization.data(withJSONObject: [
                "using": [ItemService.capability],
                "methodCalls": [
                    ["TractandaItem/history", ["itemID": item.itemID, "limit": 1], "history"],
                    ["TractandaItem/get", ["ids": [item.itemID], "projection": "summary"], "get"],
                ],
            ])
            let response = try await coordinator.handle(request, forUID: accounts.service)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
            let calls = try XCTUnwrap(object["methodResponses"] as? [[Any]])
            XCTAssertEqual(calls.count, 2)
            XCTAssertEqual(calls[0][0] as? String, "TractandaItem/history")
            XCTAssertEqual((calls[0][1] as? [String: Any])?["total"] as? Int, 3)
            XCTAssertEqual(((calls[0][1] as? [String: Any])?["list"] as? [Any])?.count, 1)
            XCTAssertEqual(calls[1][0] as? String, "TractandaItem/get")
            let list = try XCTUnwrap((calls[1][1] as? [String: Any])?["list"] as? [Any])
            XCTAssertEqual(list.count, 1)
            await coordinator.close()
        }
    }

    func testAuthorizedRebuildDrainsAcceptedPooledReaderBeforeIndexSwap() async throws {
        try await fixture { root, accounts in
            var seed: ItemStore? = try ItemStore(root: root, accounts: accounts)
            _ = try seed!.configureAccess(systemConfiguration(), operationID: "pool-drain-policy")
            _ = try seed!.withAccess(forUID: accounts.alice) {
                try seed!.commit(
                    CommitRequest(
                        classID: "Item", changes: ["subject": .text("pool drain")],
                        operationID: "pool-drain-item"))
            }
            seed = nil
            let coordinator = try await ServiceCoordinator(
                opening: root, makeAccountDirectory: { accounts })
            let entered = expectation(description: "Accepted pooled reader holds a lease")
            let release = DispatchSemaphore(value: 0)
            await coordinator.setPooledReadLeaseHookForTesting {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 10)
            }
            let queryRequest = try nativeRequest("TractandaItem/query", ["limit": 1])
            let reading = Task {
                try await coordinator.handle(queryRequest, forUID: accounts.administrator)
            }
            await fulfillment(of: [entered], timeout: 5)
            let finished = CompletionFlag()
            let rebuildRequest = try nativeRequest("TractandaStore/rebuild", [:])
            let rebuilding = Task {
                let result = try await coordinator.handle(rebuildRequest, forUID: accounts.administrator)
                await finished.mark()
                return result
            }
            var exclusive = false
            for _ in 0..<100 {
                exclusive = await coordinator.pooledExclusiveWaitingForTesting()
                if exclusive { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(exclusive)
            let completedBeforeDrain = await finished.value()
            XCTAssertFalse(completedBeforeDrain)
            release.signal()
            _ = try await reading.value
            let rebuilt = try await rebuilding.value
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: rebuilt) as? [String: Any])
            let call = try XCTUnwrap((object["methodResponses"] as? [[Any]])?.first)
            XCTAssertEqual(call[0] as? String, "TractandaStore/rebuild")
            await coordinator.setPooledReadLeaseHookForTesting(nil)
            await coordinator.close()
        }
    }

    func testPooledFinalRecheckAllowsRebuildAndCloseToDrain() async throws {
        try await fixture { root, accounts in
            var seed: ItemStore? = try ItemStore(root: root, accounts: accounts)
            _ = try seed!.commit(
                CommitRequest(
                    classID: "Item", changes: ["subject": .text("final recheck")],
                    operationID: "pool-final-item"))
            seed = nil
            let coordinator = try await ServiceCoordinator(
                opening: root, makeAccountDirectory: { accounts })
            let gate = PreparedReadGate()
            await coordinator.setPooledReadBeforeFinishHookForTesting { await gate.pause() }
            let query = try nativeRequest("TractandaItem/query", ["limit": 1])
            let rebuildingRequest = try nativeRequest("TractandaStore/rebuild", [:])
            let reading = Task { try await coordinator.handle(query, forUID: accounts.service) }
            try await waitForPreparedReads(1, gate: gate)
            let activeLeases = await coordinator.pooledReadLeaseCountForTesting()
            XCTAssertEqual(activeLeases, 0)
            let rebuilt = CompletionFlag()
            let rebuilding = Task {
                let result = try await coordinator.handle(
                    rebuildingRequest, forUID: accounts.service)
                await rebuilt.mark()
                return result
            }
            var finishedBeforeRelease = false
            for _ in 0..<100 {
                finishedBeforeRelease = await rebuilt.value()
                if finishedBeforeRelease { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            await gate.release()
            XCTAssertTrue(finishedBeforeRelease, "Rebuild waited on a read with no active lease.")
            let rebuiltData = try await rebuilding.value
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: rebuiltData) as? [String: Any])
            XCTAssertEqual(
                (object["methodResponses"] as? [[Any]])?.first?[0] as? String,
                "TractandaStore/rebuild")
            let readData = try await reading.value
            XCTAssertEqual(try nativePage(readData).total, 1)

            let secondGate = PreparedReadGate()
            await coordinator.setPooledReadBeforeFinishHookForTesting { await secondGate.pause() }
            let secondRead = Task { try await coordinator.handle(query, forUID: accounts.service) }
            try await waitForPreparedReads(1, gate: secondGate)
            let closed = CompletionFlag()
            let closing = Task {
                await coordinator.close()
                await closed.mark()
            }
            try await Task.sleep(for: .milliseconds(50))
            let closedBeforeRelease = await closed.value()
            XCTAssertFalse(closedBeforeRelease)
            await secondGate.release()
            _ = try await secondRead.value
            await closing.value
            let reopened = try ItemStore(root: root, accounts: accounts)
            XCTAssertTrue(reopened.isCanonicalTrusted)
        }
    }

    func testPooledMultiuserQueryCountsOnlyAuthorizedRowsAndRefreshesGroupAdmission() async throws {
        try await fixture { root, accounts in
            accounts.users[accounts.bob] = AccountIdentity(
                uid: accounts.bob, name: "bob", primaryGroupName: "staff", groupIDs: [71_001])
            let permissions: (Int64) -> ItemValue = { mode in
                .object([
                    "profile": .text(ItemPermissions.profile), "owner": .text("alice"),
                    "group": .text("staff"), "mode": .integer(mode), "acl": .object([:]),
                ])
            }
            var seed: ItemStore? = try ItemStore(root: root, accounts: accounts)
            _ = try seed!.configureAccess(systemConfiguration(), operationID: "pool-multi-policy")
            let shared = try seed!.withAccess(forUID: accounts.alice) {
                try seed!.commit(
                    CommitRequest(
                        classID: "Item",
                        changes: ["subject": .text("shared"), "permissions": permissions(0o640)],
                        operationID: "pool-multi-shared")
                ).revision
            }
            let hidden = try seed!.withAccess(forUID: accounts.alice) {
                try seed!.commit(
                    CommitRequest(
                        classID: "Item",
                        changes: ["subject": .text("hidden"), "permissions": permissions(0o600)],
                        operationID: "pool-multi-hidden")
                ).revision
            }
            seed = nil
            let coordinator = try await ServiceCoordinator(
                opening: root, makeAccountDirectory: { accounts })
            let request = try nativeRequest("TractandaItem/query", ["limit": 10])
            let initially = try await coordinator.handle(request, forUID: accounts.bob)
            XCTAssertEqual(try nativePage(initially).ids, [shared.itemID])
            XCTAssertEqual(try nativePage(initially).total, 1)
            XCTAssertFalse(try nativePage(initially).ids.contains(hidden.itemID))

            let gate = PreparedReadGate()
            await coordinator.setPooledReadBeforeFinishHookForTesting { await gate.pause() }
            let reading = Task { try await coordinator.handle(request, forUID: accounts.bob) }
            try await waitForPreparedReads(1, gate: gate)
            accounts.users[accounts.bob] = AccountIdentity(
                uid: accounts.bob, name: "bob", primaryGroupName: "service", groupIDs: [71_003])
            await gate.release()
            let rejected = try await reading.value
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: rejected) as? [String: Any])
            XCTAssertEqual(object["code"] as? String, "forbidden")
            await coordinator.setPooledReadBeforeFinishHookForTesting(nil)
            await coordinator.close()
        }
    }

    func testPooledCategoryIgnoresOtherOwnersOverridesAndCallerViewPin() async throws {
        try await fixture { root, accounts in
            accounts.users[accounts.bob] = AccountIdentity(
                uid: accounts.bob, name: "bob", primaryGroupName: "staff", groupIDs: [71_001])
            let shared: ItemValue = .object([
                "profile": .text(ItemPermissions.profile), "owner": .text("alice"),
                "group": .text("staff"), "mode": .integer(0o640), "acl": .object([:]),
            ])
            var seed: ItemStore? = try ItemStore(root: root, accounts: accounts)
            _ = try seed!.configureAccess(systemConfiguration(), operationID: "pool-personal-policy")
            let category = try seed!.withAccess(forUID: accounts.alice) {
                try seed!.commit(
                    CommitRequest(
                        classID: "Item",
                        changes: [
                            "selection": .object([
                                "language": .text(SpotlightQuery.profile),
                                "expression": .text("bucket == 1"),
                            ]),
                            "permissions": shared,
                        ], operationID: "pool-personal-category")
                ).revision
            }
            let target = try seed!.withAccess(forUID: accounts.alice) {
                try seed!.commit(
                    CommitRequest(
                        classID: "Item", changes: ["bucket": .integer(1), "permissions": shared],
                        operationID: "pool-personal-target")
                ).revision
            }
            _ = try seed!.withAccess(forUID: accounts.alice) {
                try seed!.commit(
                    CommitRequest(
                        classID: "PersonalStateItem",
                        changes: [
                            "target": .reference(ItemReference(target.itemID)),
                            "personalOverrides": .object([category.itemID: .text("exclude")]),
                        ], operationID: "pool-alice-override"))
            }
            let bobPin = try seed!.withAccess(forUID: accounts.bob) {
                try seed!.commit(
                    CommitRequest(
                        classID: "PersonalStateItem",
                        changes: [
                            "target": .reference(ItemReference(target.itemID)),
                            "subject": .text("view pin only"),
                        ], operationID: "pool-bob-view-pin")
                ).revision
            }
            let oracle = try seed!.withAccess(forUID: accounts.bob) {
                try Categories.query(store: seed!, categoryPath: [category.itemID]).map(\.itemID)
            }
            XCTAssertTrue(oracle.contains(target.itemID))
            seed = nil
            let coordinator = try await ServiceCoordinator(
                opening: root, makeAccountDirectory: { accounts })
            let leased = expectation(description: "Unrelated personal state did not block pooling")
            await coordinator.setPooledReadLeaseHookForTesting { leased.fulfill() }
            let response = try await coordinator.handle(
                nativeRequest(
                    "TractandaItem/query",
                    [
                        "categoryPath": [category.itemID], "limit": 10,
                    ]), forUID: accounts.bob)
            XCTAssertEqual(try nativePage(response).ids, oracle)
            await fulfillment(of: [leased], timeout: 5)
            await coordinator.setPooledReadLeaseHookForTesting(nil)

            let change = CommitRequest(
                action: .revise, itemID: bobPin.itemID,
                expectedRevisionID: bobPin.revisionID,
                changes: ["personalOverrides": .object([category.itemID: .text("exclude")])],
                operationID: "pool-bob-relevant-exclude")
            let arguments = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSON.encode(change)) as? [String: Any])
            _ = try await coordinator.handle(
                nativeRequest("TractandaItem/commit", arguments), forUID: accounts.bob)
            let exactFallback = try await coordinator.handle(
                nativeRequest(
                    "TractandaItem/query",
                    [
                        "categoryPath": [category.itemID], "limit": 10,
                    ]), forUID: accounts.bob)
            XCTAssertFalse(try nativePage(exactFallback).ids.contains(target.itemID))
            await coordinator.close()
        }
    }

    func testCancelledPooledRequestReleasesLeaseWithoutSerialRetry() async throws {
        try await fixture { root, accounts in
            var seed: ItemStore? = try ItemStore(root: root, accounts: accounts)
            _ = try seed!.commit(
                CommitRequest(
                    classID: "Item", changes: ["subject": .text("cancel")],
                    operationID: "pool-cancel-item"))
            seed = nil
            let coordinator = try await ServiceCoordinator(
                opening: root, makeAccountDirectory: { accounts })
            let entered = expectation(description: "Pooled lease accepted before cancellation")
            let release = DispatchSemaphore(value: 0)
            await coordinator.setPooledReadLeaseHookForTesting {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 10)
            }
            let request = try nativeRequest("TractandaItem/query", ["limit": 1])
            let reading = Task { try await coordinator.handle(request, forUID: accounts.service) }
            await fulfillment(of: [entered], timeout: 5)
            reading.cancel()
            release.signal()
            do {
                _ = try await reading.value
                XCTFail("Cancelled pooled request returned a serial response.")
            } catch is CancellationError {
                // A canceled worker must not retry through the serial handler.
            }
            let active = await coordinator.pooledReadLeaseCountForTesting()
            XCTAssertEqual(active, 0)
            await coordinator.setPooledReadLeaseHookForTesting(nil)
            let fresh = try await coordinator.handle(request, forUID: accounts.service)
            XCTAssertEqual(try nativePage(fresh).total, 1)
            await coordinator.close()
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

    private actor CompletionFlag {
        private var completed = false
        func mark() { completed = true }
        func value() -> Bool { completed }
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

    func testAuthorizedRebuildDrainsHeldVerifierWithoutDrainingInvalidRequests() async throws {
        try await fixture { root, accounts in
            var seed: ItemStore? = try ItemStore(root: root, accounts: accounts)
            _ = try seed!.configureAccess(systemConfiguration(), operationID: "verifier-drain-policy")
            seed = nil
            let coordinator = try await ServiceCoordinator(opening: root, makeAccountDirectory: { accounts })
            let gate = PreparedReadGate()
            await coordinator.setVerificationScanHookForTesting { await gate.pause() }
            await coordinator.startCanonicalVerification(every: .seconds(3600))
            try await waitForPreparedReads(1, gate: gate)

            let rebuild = try nativeRequest("TractandaStore/rebuild", [:], id: "rebuild")
            let denied = try await coordinator.handle(rebuild, forUID: accounts.alice)
            let deniedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: denied) as? [String: Any])
            let deniedCall = try XCTUnwrap((deniedObject["methodResponses"] as? [[Any]])?.first)
            XCTAssertEqual((deniedCall[1] as? [String: Any])?["type"] as? String, "forbidden")
            let malformed = try nativeRequest(
                "TractandaStore/rebuild", ["unexpected": true], id: "malformed")
            let rejected = try await coordinator.handle(malformed, forUID: accounts.administrator)
            let rejectedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: rejected) as? [String: Any])
            let rejectedCall = try XCTUnwrap((rejectedObject["methodResponses"] as? [[Any]])?.first)
            XCTAssertEqual((rejectedCall[1] as? [String: Any])?["type"] as? String, "invalidArguments")
            let arrivals = await gate.count()
            XCTAssertEqual(arrivals, 1)

            let finished = CompletionFlag()
            let accepted = Task {
                let response = try await coordinator.handle(rebuild, forUID: accounts.administrator)
                await finished.mark()
                return response
            }
            try await Task.sleep(for: .milliseconds(50))
            let completedBeforeDrain = await finished.value()
            XCTAssertFalse(completedBeforeDrain, "Rebuild must await the accepted verifier lease.")
            await coordinator.setVerificationScanHookForTesting(nil)
            await gate.release()
            let response = try await accepted.value
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
            let call = try XCTUnwrap((object["methodResponses"] as? [[Any]])?.first)
            XCTAssertEqual(call[0] as? String, "TractandaStore/rebuild")
            await coordinator.close()
        }
    }

    func testLiveSeekCursorPagesForwardBackwardAndRejectsTampering() async throws {
        try await fixture { root, accounts in
            accounts.users[accounts.bob] = AccountIdentity(
                uid: accounts.bob, name: "bob", primaryGroupName: "staff", groupIDs: [71_001])
            var seed: ItemStore? = try ItemStore(root: root, accounts: accounts)
            _ = try seed!.configureAccess(systemConfiguration(), operationID: "cursor-policy")
            var expected: [String] = []
            for index in 0..<3 {
                expected.append(
                    try seed!.withAccess(forUID: accounts.alice) {
                        try seed!.commit(
                            CommitRequest(
                                classID: "Item",
                                changes: ["subject": .text("cursor-\(index)"), "priority": .integer(9)],
                                operationID: "cursor-\(index)")
                        ).revision.itemID
                    })
            }
            let scalar = try SpotlightQuery("priority == 9")
            let seekPlan = try seed!.cursorSeekQueryPlanForTesting(
                order: .modifiedAt, classEquals: nil, candidatePlan: scalar.boundedIndexCandidatePlan)
            XCTAssertTrue(
                seekPlan.contains(where: { $0.contains("item_order") }), seekPlan.joined(separator: "\n"))
            seed = nil
            let coordinator = try await ServiceCoordinator(opening: root, makeAccountDirectory: { accounts })
            func verifyAdminCursor(for criteria: [String: Any]) async throws {
                var oracleArguments = criteria
                oracleArguments["position"] = 0
                oracleArguments["limit"] = 64
                let oracleResponse = try await coordinator.handle(
                    nativeRequest("TractandaItem/query", oracleArguments), forUID: accounts.administrator)
                let oracle = try nativePage(oracleResponse)
                var firstArguments = criteria
                firstArguments["limit"] = 2
                let firstResponse = try await coordinator.handle(
                    nativeRequest("TractandaItem/query", firstArguments), forUID: accounts.administrator)
                let firstObject = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: firstResponse) as? [String: Any])
                let first = try XCTUnwrap(
                    (firstObject["methodResponses"] as? [[Any]])?.first?[1] as? [String: Any])
                let firstIDs = try XCTUnwrap(first["ids"] as? [String])
                let next = try XCTUnwrap(first["nextCursor"] as? String)
                var nextArguments = criteria
                nextArguments["cursor"] = next
                nextArguments["limit"] = 2
                let nextResponse = try await coordinator.handle(
                    nativeRequest("TractandaItem/query", nextArguments), forUID: accounts.administrator)
                let nextObject = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: nextResponse) as? [String: Any])
                let nextPage = try XCTUnwrap(
                    (nextObject["methodResponses"] as? [[Any]])?.first?[1] as? [String: Any])
                XCTAssertEqual(firstIDs + (nextPage["ids"] as? [String] ?? []), oracle.ids)
            }
            try await verifyAdminCursor(for: [:])
            try await verifyAdminCursor(for: ["expression": "classID == \"Item\""])
            try await verifyAdminCursor(for: ["expression": "priority == 9"])
            let oracleData = try await coordinator.handle(
                nativeRequest(
                    "TractandaItem/query", ["expression": "priority == 9", "position": 0, "limit": 3]),
                forUID: accounts.alice)
            let oracle = try nativePage(oracleData)
            let fixedClock = "2026-09-27T12:34:56.123Z"
            let firstData = try await coordinator.handle(
                nativeRequest(
                    "TractandaItem/query",
                    [
                        "expression": "priority == 9", "limit": 2, "at": fixedClock,
                        "timeZone": "Europe/Vienna",
                    ]),
                forUID: accounts.alice)
            let firstResponse = try XCTUnwrap(JSONSerialization.jsonObject(with: firstData) as? [String: Any])
            let firstResult = try XCTUnwrap(
                (firstResponse["methodResponses"] as? [[Any]])?.first?[1] as? [String: Any])
            let firstIDs = try XCTUnwrap(firstResult["ids"] as? [String])
            XCTAssertEqual(firstIDs.count, 2)
            let next = try XCTUnwrap(firstResult["nextCursor"] as? String)
            let firstClock = try XCTUnwrap(firstResult["evaluatedAt"] as? String)
            let firstState = try XCTUnwrap(firstResult["queryState"] as? String)
            XCTAssertEqual(firstClock, fixedClock)
            let crossUserData = try await coordinator.handle(
                nativeRequest(
                    "TractandaItem/query", ["expression": "priority == 9", "cursor": next, "limit": 2]),
                forUID: accounts.bob)
            let crossUser = try XCTUnwrap(JSONSerialization.jsonObject(with: crossUserData) as? [String: Any])
            let crossUserCall = try XCTUnwrap((crossUser["methodResponses"] as? [[Any]])?.first)
            XCTAssertEqual((crossUserCall[1] as? [String: Any])?["type"] as? String, "invalidCursor")
            let privatePermissions = ItemValue.object([
                "profile": .text(ItemPermissions.profile), "owner": .text("bob"),
                "group": .text("staff"), "mode": .integer(0o600),
                "acl": .object([
                    "users": .object(["cursor-unresolved-user": .integer(4)]),
                    "mask": .integer(0), "owningGroup": .integer(0),
                ]),
            ])
            let privateItem = CommitRequest(
                classID: "Item",
                changes: [
                    "subject": .text("private cursor prefix"), "priority": .integer(9),
                    "permissions": privatePermissions,
                ],
                operationID: "cursor-private-prefix")
            let privateArgs = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSON.encode(privateItem)) as? [String: Any])
            _ = try await coordinator.handle(
                nativeRequest("TractandaItem/commit", privateArgs, id: "private-write"),
                forUID: accounts.bob)
            let secondData = try await coordinator.handle(
                nativeRequest(
                    "TractandaItem/query", ["expression": "priority == 9", "cursor": next, "limit": 2]),
                forUID: accounts.alice)
            let secondResponse = try XCTUnwrap(
                JSONSerialization.jsonObject(with: secondData) as? [String: Any])
            let secondResult = try XCTUnwrap(
                (secondResponse["methodResponses"] as? [[Any]])?.first?[1] as? [String: Any])
            XCTAssertEqual(secondResult["evaluatedAt"] as? String, firstClock)
            XCTAssertEqual(secondResult["queryState"] as? String, firstState)
            let secondIDs = try XCTUnwrap(secondResult["ids"] as? [String])
            XCTAssertEqual(secondIDs.count, 1)
            XCTAssertEqual(firstIDs + secondIDs, oracle.ids)
            let previous = try XCTUnwrap(secondResult["previousCursor"] as? String)
            let backData = try await coordinator.handle(
                nativeRequest(
                    "TractandaItem/query", ["expression": "priority == 9", "cursor": previous, "limit": 5]),
                forUID: accounts.alice)
            let backResponse = try XCTUnwrap(JSONSerialization.jsonObject(with: backData) as? [String: Any])
            let backResult = try XCTUnwrap(
                (backResponse["methodResponses"] as? [[Any]])?.first?[1] as? [String: Any])
            XCTAssertEqual(backResult["ids"] as? [String], firstIDs)
            XCTAssertEqual(backResult["position"] as? Int, 0)
            XCTAssertNil(backResult["previousCursor"] as? String)
            let wrongZoneData = try await coordinator.handle(
                nativeRequest(
                    "TractandaItem/query",
                    ["expression": "priority == 9", "cursor": next, "limit": 2, "timeZone": "UTC"]),
                forUID: accounts.alice)
            let wrongZone = try XCTUnwrap(JSONSerialization.jsonObject(with: wrongZoneData) as? [String: Any])
            let wrongZoneCall = try XCTUnwrap((wrongZone["methodResponses"] as? [[Any]])?.first)
            XCTAssertEqual((wrongZoneCall[1] as? [String: Any])?["type"] as? String, "invalidCursor")
            let otherRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
                "tractanda-cursor-other-\(Identifier.make())")
            defer { try? FileManager.default.removeItem(at: otherRoot) }
            var otherSeed: ItemStore? = try ItemStore(root: otherRoot, accounts: accounts)
            _ = try otherSeed!.configureAccess(systemConfiguration(), operationID: "cursor-other-policy")
            otherSeed = nil
            let otherCoordinator = try await ServiceCoordinator(
                opening: otherRoot, makeAccountDirectory: { accounts })
            let crossStoreData = try await otherCoordinator.handle(
                nativeRequest(
                    "TractandaItem/query", ["expression": "priority == 9", "cursor": next, "limit": 2]),
                forUID: accounts.alice)
            let crossStore = try XCTUnwrap(
                JSONSerialization.jsonObject(with: crossStoreData) as? [String: Any])
            let crossStoreCall = try XCTUnwrap((crossStore["methodResponses"] as? [[Any]])?.first)
            XCTAssertEqual((crossStoreCall[1] as? [String: Any])?["type"] as? String, "invalidCursor")
            await otherCoordinator.close()
            let ambiguous = try await coordinator.handle(
                nativeRequest(
                    "TractandaItem/query",
                    ["expression": "priority == 9", "cursor": next, "position": 1, "limit": 2]),
                forUID: accounts.alice)
            let ambiguousResult = try XCTUnwrap(
                JSONSerialization.jsonObject(with: ambiguous) as? [String: Any])
            let ambiguousCall = try XCTUnwrap((ambiguousResult["methodResponses"] as? [[Any]])?.first)
            XCTAssertEqual((ambiguousCall[1] as? [String: Any])?["type"] as? String, "invalidArguments")
            let tampered = String(next.dropLast()) + (next.last == "A" ? "B" : "A")
            let badData = try await coordinator.handle(
                nativeRequest(
                    "TractandaItem/query", ["expression": "priority == 9", "cursor": tampered, "limit": 2]),
                forUID: accounts.alice)
            let badResponse = try XCTUnwrap(JSONSerialization.jsonObject(with: badData) as? [String: Any])
            let badCall = try XCTUnwrap((badResponse["methodResponses"] as? [[Any]])?.first)
            XCTAssertEqual((badCall[1] as? [String: Any])?["type"] as? String, "invalidCursor")
            let edit = CommitRequest(
                classID: "Item", changes: ["subject": .text("state change")], operationID: "cursor-state-edit"
            )
            let editArgs = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSON.encode(edit)) as? [String: Any])
            _ = try await coordinator.handle(
                nativeRequest("TractandaItem/commit", editArgs, id: "cursor-write"),
                forUID: accounts.alice)
            let staleData = try await coordinator.handle(
                nativeRequest(
                    "TractandaItem/query", ["expression": "priority == 9", "cursor": next, "limit": 2]),
                forUID: accounts.alice)
            let staleResponse = try XCTUnwrap(JSONSerialization.jsonObject(with: staleData) as? [String: Any])
            let staleCall = try XCTUnwrap((staleResponse["methodResponses"] as? [[Any]])?.first)
            XCTAssertEqual((staleCall[1] as? [String: Any])?["type"] as? String, "invalidCursor")
            XCTAssertEqual(expected.count, 3)
            await coordinator.close()
        }
    }

    func testDeepCursorSeekUsesOrderIndexAndDoesNotRecountPriorPages() async throws {
        try await fixture { root, accounts in
            var store: ItemStore? = try ItemStore(root: root, accounts: accounts)
            for index in 0..<32 {
                if index.isMultiple(of: 16) { try guardBoundedFixture(root, nextItems: 16) }
                _ = try store!.commit(
                    CommitRequest(
                        classID: "Item",
                        changes: ["subject": .text("deep-\(index)"), "priority": .integer(9)],
                        operationID: "deep-cursor-\(index)"))
            }
            let predicate = try SpotlightQuery("priority == 9")
            let date = Date()
            let calendar = try QueryCalendar.make(timeZone: "UTC")
            let oracle = try Categories.page(
                store: store!, expression: "priority == 9", text: nil, categoryPath: [],
                excludedCategoryIDs: [], sort: [], position: 24, limit: 4, at: date, timeZone: "UTC")
            let boundaryID = try XCTUnwrap(oracle.ids.last)
            let plan = try store!.cursorSeekQueryPlanForTesting(
                order: .modifiedAt, classEquals: nil, candidatePlan: predicate.boundedIndexCandidatePlan)
            XCTAssertTrue(plan.contains(where: { $0.contains("item_order") }), plan.joined(separator: "\n"))
            store!.resetCursorSeekVMInstructionsForTesting()
            let page = try store!.indexedSeekPage(
                order: .modifiedAt, classEquals: nil,
                boundary: try store!.cursorSortValue(itemID: boundaryID, field: "modifiedAt"),
                boundaryID: boundaryID, previous: false, limit: 4, knownTotal: oracle.total,
                candidatePlan: predicate.boundedIndexCandidatePlan, needsFullRevision: true,
                accepts: { predicate.matches($0, at: date, calendar: calendar) })
            let expected = try Categories.page(
                store: store!, expression: "priority == 9", text: nil, categoryPath: [],
                excludedCategoryIDs: [], sort: [], position: 28, limit: 4, at: date, timeZone: "UTC")
            XCTAssertEqual(page.ids, expected.ids)
            XCTAssertEqual(page.total, oracle.total)
            XCTAssertLessThan(store!.cursorSeekVMInstructionsForTesting, 1_000)
            store = nil
        }
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
