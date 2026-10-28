import CTractandaPlatform
import XCTest

@testable import TractandaCore

final class AtomicAuthorityProducerTests: XCTestCase {
    func testCurrentPersonalFreshAndJoiningReplicaNeedNoAuditGenesis() throws {
        let f = try RetiredAuthorityEntryPointTests.Fixture()
        let sourceIdentity = try f.store.personalSyncIdentity()
        XCTAssertFalse(try f.store.verificationSnapshot().authorityEnforced)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: f.storeRoot.appendingPathComponent("authority").path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: f.storeRoot.appendingPathComponent(".peer-configuration").path))
        let joiningRoot = f.root.appendingPathComponent("joining")
        var joining: ItemStore? = try ItemStore.createPersonalSyncReplica(
            root: joiningRoot, storeID: sourceIdentity.storeID,
            accessConfiguration: RetiredAuthorityEntryPointTests.Fixture.policy, accounts: f.accounts)
        let joiningIdentity = try joining!.personalSyncIdentity()
        XCTAssertEqual(joiningIdentity.storeID, sourceIdentity.storeID)
        XCTAssertNotEqual(joiningIdentity.replicaID, sourceIdentity.replicaID)
        XCTAssertFalse(try joining!.verificationSnapshot().authorityEnforced)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: joiningRoot.appendingPathComponent("authority").path))
        joining = nil
        f.store = nil
        f.store = try ItemStore.openInitialized(root: f.storeRoot, accounts: f.accounts)
        XCTAssertEqual(try f.store.personalSyncIdentity(), sourceIdentity)
        XCTAssertEqual(try f.store.history(f.revision.itemID), [f.revision])
        XCTAssertFalse(try f.store.verificationSnapshot().authorityEnforced)
    }

    func testDescriptorSpoolRetainsFullRootBoundDescriptorAndLexicalOrder() throws {
        let f = try AtomicAuthorityStoreFixture()
        let index = try ItemIndex(
            path: f.sourceRoot.appendingPathComponent("index/items.sqlite").path, create: false)
        defer { index.close() }
        try index.installAtomicAuthorityIndexSchema(.publication)
        let token = "publication-fixture"
        defer { try? index.execute("DELETE FROM authority_atomic_publication_spool WHERE token=?", [token]) }
        let ids = try (0..<3).map { _ in try UUID.makeVersion1().uuidString.lowercased() }.sorted()
        let descriptors = ids.map {
            PeerPackage.Object(
                kind: .authority, id: $0, length: 32, sha256: String(repeating: "a", count: 64))
        }
        try index.withAtomicPublicationSpool {
            var bytes: UInt64 = 0
            for object in descriptors.reversed() {
                XCTAssertTrue(
                    try index.spoolAtomicPublicationDescriptor(object, token: token, storedBytes: &bytes))
            }
            XCTAssertEqual(
                try index.atomicPublicationDescriptorPage(token: token, afterID: nil, limit: 2),
                Array(descriptors.prefix(2)))
            XCTAssertEqual(
                try index.atomicPublicationDescriptorPage(token: token, afterID: ids[1], limit: 2),
                [descriptors[2]])
            XCTAssertFalse(
                try index.spoolAtomicPublicationDescriptor(descriptors[0], token: token, storedBytes: &bytes))
            XCTAssertThrowsError(try index.withAtomicPublicationSpool { () })
        }
        XCTAssertEqual(try index.atomicPublicationDescriptorPage(token: token, afterID: nil, limit: 2), [])
        try f.capacity()
    }
    func testActualSequentialWriterOriginalPREWorkAt16And32Operations() throws {
        let f = try AtomicAuthorityStoreFixture()
        try f.activateAndOpen()
        var operationUnits: [Int64] = []
        var units: Int64 = 0
        f.source.atomicOriginalPREWorkForTesting = { units += $0 }
        defer { f.source.atomicOriginalPREWorkForTesting = nil }
        for ordinal in 1...32 {
            units = 0
            let result = try f.source.commit(
                .init(
                    classID: "Item", changes: ["subject": .text("bounded PRE measurement")],
                    operationID: "atomic-pre-measure-\(ordinal)"))
            XCTAssertTrue(result.isIndexReady, result.warnings.joined(separator: "\n"))
            operationUnits.append(units)
            if ordinal % 4 == 0 { try f.capacity() }
            if ordinal == 16 || ordinal == 32 {
                print(
                    "ATOMIC_ACTUAL_WRITER_PRE operations=\(ordinal) perOperationUnits=\(operationUnits) total=\(operationUnits.reduce(0,+))"
                )
            }
        }
        XCTAssertEqual(operationUnits.count, 32)
        XCTAssertFalse(StoreCheckpoint.isDirty(root: f.sourceRoot))
    }

}
