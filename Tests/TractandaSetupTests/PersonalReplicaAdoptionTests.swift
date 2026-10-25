import CTractandaPlatform
import Foundation
import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class PersonalReplicaAdoptionTests: XCTestCase {
    private func requireCapacity(at directory: URL = FileManager.default.temporaryDirectory) throws {
        var capacity = statvfs()
        guard statvfs(directory.path, &capacity) == 0, capacity.f_frsize > 0 else {
            throw TractandaError("resourceLimit", "Cannot determine genuine fixture capacity.")
        }
        let available = UInt64(capacity.f_bavail).multipliedReportingOverflow(by: UInt64(capacity.f_frsize))
        guard !available.overflow, available.partialValue >= 10 * 1024 * 1024 * 1024 + 128 * 1024 * 1024
        else {
            throw TractandaError(
                "resourceLimit", "Personal replica fixture needs10GiB reserve and128MiB allowance.")
        }
    }
    private func fixture(_ body: (URL, ItemValue) throws -> Void) throws {
        // Two tiny stores and rebuilt indexes are estimated below16MiB.
        try requireCapacity()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tpa-" + String(UUID().uuidString.prefix(8)))
        try PrivateConfiguration.makeDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try SystemAccountDirectory().user(forUID: tractanda_uid())
        let access = ItemValue.object([
            "profile": .text(AccessConfiguration.profile), "users": .list([.text(account.name)]),
        ])
        try body(root, access)
        try requireCapacity(at: root)
        let entries = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var bytes: UInt64 = 0
        for case let file as URL in entries {
            let metadata = try FileMetadata.read(at: file)
            if metadata.type == .regular { bytes += metadata.size }
        }
        XCTAssertLessThanOrEqual(bytes, 128 * 1024 * 1024)
    }
    func testPersonalReplicaAdoptionNeedsOnlyCurrentProfileCustodyAndExactPins() throws {
        try fixture { root, access in
            let replica = root.appendingPathComponent("replica")
            let index = root.appendingPathComponent("index")
            let storeID = try UUID.makeVersion1().uuidString.lowercased()
            let replicaID: String
            do {
                let store = try ItemStore.createPersonalSyncReplica(
                    root: replica, storeID: storeID, accessConfiguration: access)
                replicaID = try store.personalSyncIdentity().replicaID
            }
            // No activation receipt, historical ledger or replication database is an input.
            try ItemStore.verifyPersonalSyncReplicaIdentityForSetup(
                root: replica, ownerUID: tractanda_uid(),
                expectedStoreID: storeID, expectedReplicaID: replicaID)
            try ItemStore.verifyPersonalSyncReplicaForSetup(
                root: replica, indexDirectory: index,
                expectedStoreID: storeID, expectedReplicaID: replicaID)
            try FileManager.default.removeItem(at: index)
            try ItemStore.verifyPersonalSyncReplicaForSetup(
                root: replica, indexDirectory: index,
                expectedStoreID: storeID, expectedReplicaID: replicaID)
            let reopened = try ItemStore.openInitialized(root: replica, indexDirectory: index)
            XCTAssertEqual(try reopened.personalSyncIdentity().replicaID, replicaID)
        }
    }
    func testPersonalReplicaAdoptionRejectsDifferentPinsAndStandaloneFactory() throws {
        try fixture { root, access in
            let replica = root.appendingPathComponent("replica")
            let standalone = root.appendingPathComponent("standalone")
            let storeID = try UUID.makeVersion1().uuidString.lowercased()
            let replicaID: String
            do {
                let store = try ItemStore.createPersonalSyncReplica(
                    root: replica, storeID: storeID, accessConfiguration: access)
                replicaID = try store.personalSyncIdentity().replicaID
            }
            XCTAssertThrowsError(
                try ItemStore.verifyPersonalSyncReplicaIdentityForSetup(
                    root: replica, ownerUID: tractanda_uid(),
                    expectedStoreID: storeID, expectedReplicaID: UUID.makeVersion1().uuidString.lowercased()))
            XCTAssertThrowsError(
                try ItemStore.verifyPersonalSyncReplicaIdentityForSetup(
                    root: replica, ownerUID: tractanda_uid() == 1 ? 2 : 1,
                    expectedStoreID: storeID, expectedReplicaID: replicaID))
            let identity: PersonalSyncIdentity
            do {
                let store = try ItemStore.initializePersonalWorkgroup(
                    root: standalone, accessConfiguration: access)
                identity = try store.personalSyncIdentity()
            }
            XCTAssertThrowsError(
                try ItemStore.verifyPersonalSyncReplicaIdentityForSetup(
                    root: standalone, ownerUID: tractanda_uid(),
                    expectedStoreID: identity.storeID, expectedReplicaID: identity.replicaID))
            try ItemStore.verifyPersonalSyncReplicaIdentityForSetup(
                root: replica, ownerUID: tractanda_uid(),
                expectedStoreID: storeID, expectedReplicaID: replicaID)
        }
    }
}
