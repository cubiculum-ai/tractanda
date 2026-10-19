import CTractandaPlatform
import Foundation
import XCTest
@testable import TractandaCore

final class InitialAuthorityBootstrapTests: XCTestCase {
    typealias Accounts = PeerIntakeStoreTests.Accounts
    private var policy: ItemValue {
        .object(["profile": .text(AccessConfiguration.profile), "users": .list([.text("admin"), .text("alice")])])
    }
    private func directory() throws -> URL {
        try AttachmentFixtureCapacity.requireFree()
        let url = (try GuardedFixtureDirectory.parent()).appendingPathComponent("tractanda-first-source-" + Identifier.make())
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }
    private func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }
    private func create(_ root: URL, operation: String, progress: ((String) throws -> Void)? = nil) throws -> ItemStore {
        try ItemStore.createInitialized(root: root, accounts: Accounts(), initialAccessConfiguration: policy,
            actorUID: tractanda_uid(), operationID: operation, progress: progress)
    }
    private func open(_ root: URL) throws -> ItemStore {
        try ItemStore(root: root, accounts: Accounts(), revisionProjectionEnabled: true, authorityIntakeEnabled: true)
    }
    func testFreshCreationPinsItsFoundingPolicyAndNextWriteHasAuthority() throws {
        let parent = try directory(); defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("new")
        let operation = try id()
        var store: ItemStore? = try create(root, operation: operation)
        let replica = try XCTUnwrap(store!.replicaID)
        let sid = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(".tractanda-store-identity.json"))) as! [String: Any]
        let storeID = try XCTUnwrap(sid["storeID"] as? String)
        XCTAssertNotEqual(replica, storeID)
        XCTAssertNotNil(UUID(uuidString: replica)?.version1Components)
        XCTAssertNotNil(UUID(uuidString: storeID)?.version1Components)
        let configuration = try XCTUnwrap(AuthorityStore.configuration(root: root,
            files: DocumentContentFiles(root: root, ownerUID: tractanda_uid(), minimumFreeBytes: 0)))
        XCTAssertNotNil(configuration.bootstrap)
        let revision = try store!.withAccess(forUID: Accounts().alice) {
            try store!.commit(.init(classID: "Item", changes: ["subject": .text("initialized")], operationID: "next")).revision
        }
        XCTAssertEqual(try revision.provenance?.originReplicaID, replica)
        store = nil
        store = try create(root, operation: operation)
        XCTAssertEqual(store!.replicaID, replica)
        XCTAssertEqual(try store!.get(revision.itemID), revision)
        XCTAssertThrowsError(try ItemStore(root: root))
    }
    func testInterruptedCreationBeforeAndAfterPinRequiresExactRetry() throws {
        for boundary in ["beforePin", "afterPin", "beforeComplete"] {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let operation = try id()
            XCTAssertThrowsError(try create(root, operation: operation) { phase in
                if phase == boundary { throw CancellationError() }
            })
            let replica = try Data(contentsOf: root.appendingPathComponent(ReplicaIdentity.name))
            let request = try XCTUnwrap(InitialAuthorityBootstrap.load(root: root))
            XCTAssertThrowsError(try open(root)) { XCTAssertEqual(($0 as? TractandaError)?.code, "firstSourcePending") }
            XCTAssertThrowsError(try create(root, operation: id()))
            let store = try create(root, operation: operation)
            XCTAssertEqual(try InitialAuthorityBootstrap.load(root: root), request)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(ReplicaIdentity.name)), replica)
            XCTAssertTrue(try InitialAuthorityBootstrap.completed(root: root, request: request))
            _ = try store.commit(.init(classID: "Item", changes: ["subject": .text("retry")], operationID: "after-retry"))
        }
    }
    func testCapturedFoundingPolicyRemainsUnreadableBeforePinAndReusesExactBytes() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let operation = try id()
        XCTAssertThrowsError(try create(root, operation: operation) {
            if $0 == "afterInitialCapture" { throw CancellationError() }
        })
        let request = try XCTUnwrap(InitialAuthorityBootstrap.load(root: root))
        let founding = try XCTUnwrap(request.foundingPolicy)
        let original = try Data(contentsOf: root.appendingPathComponent(founding.original.path))
        XCTAssertEqual(original, founding.bytes)
        XCTAssertEqual(try RecordCodec.decode(original).formatVersion, 2)
        XCTAssertEqual(try FileMetadata.read(at: root.appendingPathComponent(founding.original.path)).mode & 0o777, 0o400)
        do {
            let pending = try ItemStore(root: root, accounts: Accounts(), revisionProjectionEnabled: true,
                authorityIntakeEnabled: true, firstSourceOperation: request)
            XCTAssertThrowsError(try pending.get(founding.original.itemID))
            XCTAssertThrowsError(try pending.withAccess(forUID: Accounts().alice) { try pending.get(founding.original.itemID) })
            XCTAssertThrowsError(try pending.commit(.init(classID: "Item", changes: ["subject": .text("too early")], operationID: "early")))
        }
        _ = try create(root, operation: operation)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(founding.original.path)), original)
        XCTAssertEqual(try InitialAuthorityBootstrap.load(root: root), request)
    }
    func testCapturedOriginalAndIdentityLossOrChangedOperationReceiptFailClosed() throws {
        for corruption in ["original", "bytes", "mode", "identity", "oldProfile", "reservation"] {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let operation = try id()
            XCTAssertThrowsError(try create(root, operation: operation) {
                if $0 == "afterInitialCapture" { throw CancellationError() }
            })
            let request = try XCTUnwrap(InitialAuthorityBootstrap.load(root: root))
            let founding = try XCTUnwrap(request.foundingPolicy)
            let original = root.appendingPathComponent(founding.original.path)
            switch corruption {
            case "original": try FileManager.default.removeItem(at: original)
            case "bytes":
                try FileManager.default.removeItem(at: original)
                try Data("changed canonical original".utf8).write(to: original)
                try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: original.path)
            case "mode": try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: original.path)
            case "identity": try FileManager.default.removeItem(at: root.appendingPathComponent(ReplicaIdentity.name))
            default:
                let path = root.appendingPathComponent(InitialAuthorityBootstrap.receiptName)
                var object = try JSONSerialization.jsonObject(with: JSON.encode(request)) as! [String: Any]
                if corruption == "oldProfile" { object["profile"] = "tractanda.first-source.v1" }
                else { object.removeValue(forKey: "foundingPolicy") }
                let changed = try JSONSerialization.data(withJSONObject: object)
                let decoded = try JSON.decode(InitialAuthorityBootstrap.Request.self, changed)
                try FileManager.default.removeItem(at: path)
                try JSON.encode(decoded).write(to: path)
                try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: path.path)
            }
            XCTAssertThrowsError(try create(root, operation: operation), corruption)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(InitialAuthorityBootstrap.completeName).path))
            XCTAssertNil(try AuthorityStore.configuration(root: root, files: InitialAuthorityBootstrap.files(root))?.bootstrap)
        }
    }
    func testDeniedCreationAndPopulatedOrPreparedRootsFailClosed() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try ItemStore.createInitialized(root: root, accounts: Accounts(),
            initialAccessConfiguration: policy, actorUID: Accounts().alice, operationID: id())) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "forbidden")
        }
        XCTAssertNil(try InitialAuthorityBootstrap.load(root: root))
        do { _ = try ItemStore(root: root) }
        XCTAssertThrowsError(try create(root, operation: id()))
        let prepared = try directory(); defer { try? FileManager.default.removeItem(at: prepared) }
        _ = try PeerEnrollment.prepareTarget(root: prepared, commonStoreID: id(), sourceReplicaID: id())
        XCTAssertThrowsError(try create(prepared, operation: id())) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "enrollmentPending")
        }
    }
    func testCapacityUnknownLowAndTotalPoliciesFailClosed() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let limits = InitialAuthorityBootstrap.Limits()
        XCTAssertThrowsError(try InitialAuthorityBootstrap.capacity(root: root, limits: limits, available: { 0 }))
        XCTAssertThrowsError(try InitialAuthorityBootstrap.capacity(root: root, limits: limits, available: { throw CancellationError() }))
        var bad = limits; bad.maximumRecords = 0
        XCTAssertThrowsError(try bad.validate())
        bad = limits; bad.reserveBytes = UInt64.max
        XCTAssertThrowsError(try InitialAuthorityBootstrap.capacity(root: root, limits: bad, available: { UInt64.max }))
        bad = limits; bad.reserveBytes = 0
        XCTAssertThrowsError(try bad.validate())
    }
    func testMalformedFreshReceiptAndReplacedIdentityFailClosed() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let operation = try id()
        XCTAssertThrowsError(try create(root, operation: operation) { if $0 == "beforePin" { throw CancellationError() } })
        let request = try XCTUnwrap(InitialAuthorityBootstrap.load(root: root))
        let identity = root.appendingPathComponent(ReplicaIdentity.name)
        try FileManager.default.removeItem(at: identity)
        try DocumentContentFiles(root: root, ownerUID: tractanda_uid(), minimumFreeBytes: 0).writeImmutable(
            JSON.encode(ReplicaIdentity.Record(formatVersion: 1, storeID: request.freshStoreID!, replicaID: id())),
            path: [ReplicaIdentity.name], maximumBytes: 4096)
        XCTAssertThrowsError(try create(root, operation: operation))
        let malformed = try directory(); defer { try? FileManager.default.removeItem(at: malformed) }
        var object = try JSONSerialization.jsonObject(with: JSON.encode(request)) as! [String: Any]
        object.removeValue(forKey: "freshStoreID"); object.removeValue(forKey: "freshReplicaID")
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        // Canonical encoding is deliberate: rejection must not depend on incidental JSON formatting.
        let decoded = try JSON.decode(InitialAuthorityBootstrap.Request.self, bytes)
        try InitialAuthorityBootstrap.files(malformed).writeImmutable(JSON.encode(decoded),
            path: [InitialAuthorityBootstrap.receiptName], maximumBytes: InitialAuthorityBootstrap.maximumReceiptBytes)
        XCTAssertThrowsError(try InitialAuthorityBootstrap.load(root: malformed))
    }
    func testCanonicalFilesOnlyRestorePreservesIdentityHistoryACLAndRequiresTrust() throws {
        let parent = try directory(); defer { try? FileManager.default.removeItem(at: parent) }
        let source = parent.appendingPathComponent("source"), restored = parent.appendingPathComponent("restored")
        var store: ItemStore? = try create(source, operation: id())
        let accounts = Accounts()
        let first = try store!.withAccess(forUID: accounts.alice) {
            try store!.commit(.init(classID: "Item", changes: ["subject": .text("private"),
                "permissions": .object(["profile": .text(ItemPermissions.profile), "owner": .text("alice"),
                    "group": .text("staff"), "mode": .integer(0o600), "acl": .object([:])])], operationID: "first")).revision
        }
        let next = try store!.withAccess(forUID: accounts.alice) {
            try store!.commit(.init(action: .revise, itemID: first.itemID, expectedRevisionID: first.revisionID,
                changes: ["subject": .text("second")], operationID: "second")).revision
        }
        let replica = store!.replicaID
        store = nil
        // Independent backup contract: explicit canonical top-level allowlist, no source constants.
        let retained = ["items", "authority", ".tractanda-store-identity.json", ".tractanda-replica-identity.json",
            "canonical-reader.json", ".authority-initial-capture.json", ".authority-initial-state.json",
            ".authority-initial-state-sealed.json", ".authority-initial-visibility", ".peer-configuration",
            ".peer-lifecycle-operations", ".peer-retirement-activations", ".peer-review-activations",
            "attachments", "documents", ".tractanda-first-source.json", ".tractanda-first-source-complete.json"]
        try FileManager.default.createDirectory(at: restored, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        func copy(_ from: URL, _ to: URL) throws {
            let metadata = try FileMetadata.read(at: from)
            if metadata.type == .directory {
                try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                for child in try FileManager.default.contentsOfDirectory(at: from, includingPropertiesForKeys: nil) {
                    try copy(child, to.appendingPathComponent(child.lastPathComponent))
                }
            } else {
                let name = from.lastPathComponent
                guard !name.contains(".sqlite"), !name.hasSuffix("-wal"), !name.hasSuffix("-shm") else { return }
                try FileManager.default.copyItem(at: from, to: to)
            }
        }
        for name in retained where FileManager.default.fileExists(atPath: source.appendingPathComponent(name).path) {
            try copy(source.appendingPathComponent(name), restored.appendingPathComponent(name))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: restored.appendingPathComponent("index").path))
        store = try open(restored)
        XCTAssertEqual(store!.replicaID, replica)
        XCTAssertEqual(try store!.get(first.itemID, revisionID: first.revisionID), first)
        XCTAssertEqual(try store!.get(first.itemID), next)
        XCTAssertEqual(try store!.history(first.itemID).count, 2)
        XCTAssertEqual(try InitialAuthorityBootstrap.storeIdentityBytes(root: source), try InitialAuthorityBootstrap.storeIdentityBytes(root: restored))
        XCTAssertThrowsError(try store!.withAccess(forUID: accounts.bob) { try store!.get(first.itemID) })
        XCTAssertEqual(try store!.withAccess(forUID: accounts.alice) { try store!.get(first.itemID) }, next)
        store = nil
        try FileManager.default.removeItem(at: restored.appendingPathComponent(".authority-initial-state.json"))
        try FileManager.default.removeItem(at: restored.appendingPathComponent(".authority-initial-state-sealed.json"))
        try FileManager.default.removeItem(at: restored.appendingPathComponent("index"))
        XCTAssertThrowsError(try open(restored))
    }
}
