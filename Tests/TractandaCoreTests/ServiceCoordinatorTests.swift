import XCTest

@testable import TractandaCore

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
                        classID: "NoteItem", changes: ["subject": .text("Alice note")],
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
                classID: "NoteItem",
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
                    classID: "NoteItem",
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
}
