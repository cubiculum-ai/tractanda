import CTractandaPlatform
import Foundation
import XCTest

@testable import TractandaCore
@testable import TractandaSetup

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class PersonalBootstrapTests: XCTestCase {
    private final class Accounts: AccountDirectory {
        let human: UInt32 = 55001
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            if uid == tractanda_uid() {
                return .init(uid: uid, name: "daemon", primaryGroupName: "service", groupIDs: [75002])
            }
            if uid == human {
                return .init(uid: uid, name: "human", primaryGroupName: "staff", groupIDs: [75001])
            }
            throw TractandaError("unresolvedPrincipal", "Fixture account missing")
        }
        func user(named name: String) throws -> AccountIdentity {
            if name == "daemon" { return try user(forUID: tractanda_uid()) }
            if name == "human" { return try user(forUID: human) }
            throw TractandaError("unresolvedPrincipal", "Fixture account missing")
        }
        func groupID(named name: String) throws -> UInt32 {
            if ["admin", "sudo", "staff"].contains(name) { return 75001 }
            if name == "service" { return 75002 }
            throw TractandaError("unresolvedPrincipal", "Fixture group missing")
        }
    }
    func testBootstrapUsesPersonalPolicyAndOwnerAwareReadonlyValidation() throws {
        var filesystem = statvfs()
        guard statvfs(FileManager.default.temporaryDirectory.path, &filesystem) == 0,
            UInt64(filesystem.f_bavail) * UInt64(filesystem.f_frsize) >= 10 * 1024 * 1024 * 1024 + 32 * 1024
                * 1024
        else {
            throw TractandaError(
                "resourceLimit", "Setup fixture requires genuine10GiB reserve plus32MiB cap.")
        }
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tps-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("store")
        let index = parent.appendingPathComponent("index")
        let accounts = Accounts()
        try StoreBootstrap.initialize(
            store: root, indexDirectory: index, owner: "human", instance: "private-fixture",
            accounts: accounts)
        let store = try ItemStore.openInitialized(root: root, indexDirectory: index, accounts: accounts)
        XCTAssertTrue(store.isPersonalWorkgroup)
        XCTAssertThrowsError(
            try store.withAccess(forUID: tractanda_uid()) { try store.requireAdministrator() })
        _ = try store.withAccess(forUID: accounts.human) {
            try store.commit(
                .init(
                    classID: "Item", changes: ["subject": .text("human-owned")], operationID: "human-create"))
        }
        try ItemStore.verifyPersonalWorkgroupRoot(root: root, ownerUID: tractanda_uid())
        XCTAssertThrowsError(
            try ItemStore.verifyPersonalWorkgroupRoot(root: root, ownerUID: tractanda_uid() == 1 ? 2 : 1))
        XCTAssertThrowsError(try PersonalWorkgroupProfile.load(root, ownerUID: tractanda_uid() == 1 ? 2 : 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("authority").path))
    }
    func testFreshTargetBootstrapResumesIdentityAndRefusesStandalone() throws {
        var filesystem = statvfs()
        guard statvfs(FileManager.default.temporaryDirectory.path, &filesystem) == 0,
            UInt64(filesystem.f_bavail) * UInt64(filesystem.f_frsize) >= 10 * 1024 * 1024 * 1024 + 32 * 1024 * 1024
        else { throw TractandaError("resourceLimit", "Fixture requires 10GiB reserve plus 32MiB.") }
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tpt-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: parent) }
        let accounts = Accounts()
        let root = parent.appendingPathComponent("target")
        let index = parent.appendingPathComponent("external-index")
        let storeID = try UUID.makeVersion1().uuidString.lowercased()
        let first = try XCTUnwrap(StoreBootstrap.initialize(
            store: root, indexDirectory: index, owner: "human", instance: "private-fixture",
            accounts: accounts, commonStoreID: storeID))
        XCTAssertEqual(first.storeID, storeID)
        XCTAssertNotEqual(first.replicaID, storeID)
        try {
            let unopened = try ItemStore.openInitialized(root: root, indexDirectory: index, accounts: accounts)
            XCTAssertTrue(unopened.isPersonalBaselinePending)
            XCTAssertThrowsError(try unopened.withAccess(forUID: accounts.human) {
                try unopened.get("not-yet-available")
            }) { error in
                XCTAssertEqual((error as? TractandaError)?.code, "baselinePending")
            }
            XCTAssertThrowsError(try unopened.withAccess(forUID: accounts.human) {
                try unopened.commit(.init(
                    classID: "Item", changes: ["subject": .text("must-not-write")],
                    operationID: "before-join"))
            }) { error in
                XCTAssertEqual((error as? TractandaError)?.code, "baselinePending")
            }
        }()
        let retry = try XCTUnwrap(StoreBootstrap.initialize(
            store: root, indexDirectory: index, owner: "human", instance: "private-fixture",
            accounts: accounts, commonStoreID: storeID))
        XCTAssertEqual(first.replicaID, retry.replicaID)
        try {
            let reopened = try ItemStore.openInitialized(root: root, indexDirectory: index, accounts: accounts)
            XCTAssertTrue(reopened.isPersonalBaselinePending)
            let source = try UUID.makeVersion1().uuidString.lowercased()
            let status = try reopened.withAccess(forUID: accounts.human) {
                try reopened.personalPeerCanonicalStatus()
            }
            XCTAssertEqual(status.readiness, .pendingActivation)
            let selection = try reopened.withAccess(forUID: accounts.human) {
                try reopened.startPersonalBaseline(sourceReplicaID: source)
            }
            let resumed = try reopened.withAccess(forUID: accounts.human) {
                try reopened.startPersonalBaseline(sourceReplicaID: source)
            }
            XCTAssertEqual(selection, resumed)
            XCTAssertTrue(reopened.isPersonalBaselinePending)
        }()
        XCTAssertTrue(FileManager.default.fileExists(atPath: index.path))
        try ItemStore.verifyPersonalSyncReplicaIdentityForSetup(
            root: root, ownerUID: tractanda_uid(), expectedStoreID: storeID, expectedReplicaID: first.replicaID)
        let otherID = try UUID.makeVersion1().uuidString.lowercased()
        XCTAssertThrowsError(try StoreBootstrap.initialize(
            store: root, indexDirectory: index, owner: "human", instance: "private-fixture",
            accounts: accounts, commonStoreID: otherID))
        let standalone = parent.appendingPathComponent("standalone")
        let separateIndex = parent.appendingPathComponent("standalone-index")
        try StoreBootstrap.initialize(
            store: standalone, indexDirectory: separateIndex, owner: "human", instance: "standalone",
            accounts: accounts)
        let existingID = try {
            let existing = try ItemStore.openInitialized(
                root: standalone, indexDirectory: separateIndex, accounts: accounts)
            return try existing.personalSyncIdentity().storeID
        }()
        XCTAssertThrowsError(try StoreBootstrap.initialize(
            store: standalone, indexDirectory: separateIndex, owner: "human", instance: "standalone",
            accounts: accounts, commonStoreID: storeID))
        let preserved = try ItemStore.openInitialized(root: standalone, indexDirectory: separateIndex, accounts: accounts)
        XCTAssertEqual(try preserved.personalSyncIdentity().storeID, existingID)
    }

    func testFreshTargetOptionsValidateStorePinAndEmptyMode() throws {
        let storeID = try UUID.makeVersion1().uuidString.lowercased()
        let bundle = URL(fileURLWithPath: "/tmp/fixture")
        try SetupOptions(bundle: bundle, storeSelection: .freshPersonalTarget(storeID: storeID)).validate()
        XCTAssertThrowsError(try SetupOptions(
            mode: .sample, bundle: bundle, storeSelection: .freshPersonalTarget(storeID: storeID)).validate())
        XCTAssertThrowsError(try SetupOptions(
            bundle: bundle, storeSelection: .freshPersonalTarget(storeID: UUID().uuidString.lowercased())).validate())
    }

}
