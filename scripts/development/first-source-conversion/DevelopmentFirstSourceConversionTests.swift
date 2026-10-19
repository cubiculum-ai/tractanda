import CTractandaPlatform
import Foundation
import XCTest
@testable import TractandaCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private enum GuardedFixtureDirectory {
    struct Context { let root: URL; let proof: URL }
    static func validate(_ url: URL) throws -> stat {
        var info = stat()
        guard url.path.hasPrefix("/"), url.path == url.standardizedFileURL.resolvingSymlinksInPath().path,
            lstat(url.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
            info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else {
            throw TractandaError("fixtureRoot", "Fixture override must be an existing private owned physical directory.")
        }
        return info
    }
    static func context() throws -> Context? {
        let env = ProcessInfo.processInfo.environment
        let guarded = env["TRACTANDA_TEST_FIXTURE_GUARDED"]
        let root = env["TRACTANDA_TEST_FIXTURE_ROOT"]
        let proof = env["TRACTANDA_TEST_FIXTURE_PROOF"]
        if guarded == nil, root == nil, proof == nil { return nil }
        guard guarded == "1", let root, let proof, !root.contains("\0"), !proof.contains("\0") else {
            throw TractandaError("fixtureRoot", "Guarded fixture overrides are incomplete.")
        }
        let result = Context(root: URL(fileURLWithPath: root, isDirectory: true),
            proof: URL(fileURLWithPath: proof, isDirectory: true))
        guard root.hasPrefix("/"), proof.hasPrefix("/"), result.root.path == root,
            result.proof.path == proof, result.root.path != result.proof.path,
            result.root.deletingLastPathComponent().path == result.proof.deletingLastPathComponent().path,
            try validate(result.root).st_dev == validate(result.proof).st_dev else {
            throw TractandaError("fixtureRoot", "Fixture and proof overrides must be physical sibling directories.")
        }
        return result
    }
    static func parent() throws -> URL { try context()?.root ?? FileManager.default.temporaryDirectory }
    static func create(prefix: String, source: String, test: String, socket: String? = nil) throws -> URL {
        let context = try context()
        let parent = context?.root ?? FileManager.default.temporaryDirectory
        var capacity = statvfs()
        guard statvfs(parent.path, &capacity) == 0, capacity.f_frsize > 0 else {
            throw TractandaError("resourceLimit", "Cannot inspect genuine fixture capacity.")
        }
        let free = UInt64(capacity.f_bavail).multipliedReportingOverflow(by: UInt64(capacity.f_frsize))
        guard !free.overflow, free.partialValue >= 10 * 1024 * 1024 * 1024 + 16 * 1024 * 1024 else {
            throw TractandaError("resourceLimit", "Tiny fixture needs 10 GiB reserve plus its 16 MiB bound.")
        }
        let root = parent.appendingPathComponent(prefix + String(UUID().uuidString.prefix(7)))
        if let socket {
            #if os(Linux)
            let limit = 108
            #else
            let limit = 104
            #endif
            guard root.appendingPathComponent(socket).path.utf8.count < limit else {
                throw TractandaError("resourceLimit", "Configured fixture root leaves no room for a Unix socket.")
            }
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        if let context {
            let actual = root.resolvingSymlinksInPath()
            _ = try validate(actual)
            guard actual.path == root.path, actual.deletingLastPathComponent().path == context.root.path,
                test.utf8.count <= 256 else { throw TractandaError("fixtureRoot", "Fixture escaped its override.") }
            let fact: [String: Any] = ["profile": "tractanda.fixture-root-proof.v1", "source": source,
                "test": test, "root": actual.path, "expectedRoot": context.root.path,
                "proofRoot": context.proof.path, "uid": Int(geteuid()), "pid": Int(getpid()), "phase": "created"]
            let bytes = try JSONSerialization.data(withJSONObject: fact, options: [.sortedKeys])
            guard bytes.count <= 2048 else { throw TractandaError("fixtureRoot", "Fixture proof exceeds its bound.") }
            let temporary = context.root.appendingPathComponent(".fixture-proof-" + UUID().uuidString + ".tmp")
            let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw TractandaError("fixtureRoot", "Cannot create fixture proof.") }
            defer { _ = close(descriptor) }
            try bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < bytes.count {
                    let count = write(descriptor, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw TractandaError("fixtureRoot", "Cannot write fixture proof.") }
                    offset += count
                }
            }
            guard fsync(descriptor) == 0 else { throw TractandaError("fixtureRoot", "Cannot sync fixture proof.") }
            try FileManager.default.moveItem(at: temporary,
                to: context.proof.appendingPathComponent(source + "-" + root.lastPathComponent + ".json"))
            let directory = open(context.proof.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else { throw TractandaError("fixtureRoot", "Cannot open fixture proof directory.") }
            defer { _ = close(directory) }
            guard fsync(directory) == 0 else { throw TractandaError("fixtureRoot", "Cannot sync fixture proof directory.") }
        }
        return root
    }
}


final class DevelopmentFirstSourceFixtureTests: XCTestCase {
    final class Accounts: AccountDirectory {
        var administrator = true
        let alice: UInt32 = 51001
        let bob: UInt32 = 51002
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            let name = uid == tractanda_uid() ? "admin" : uid == alice ? "alice" : uid == bob ? "bob" : "unknown"
            guard name != "unknown" else { throw TractandaError("unresolvedPrincipal", "Unknown test account") }
            return .init(uid: uid, name: name, primaryGroupName: "staff",
                groupIDs: uid == tractanda_uid() && administrator ? [71001] : [])
        }
        func user(named name: String) throws -> AccountIdentity {
            switch name {
            case "admin": try user(forUID: tractanda_uid())
            case "alice": try user(forUID: alice)
            case "bob": try user(forUID: bob)
            default: throw TractandaError("unresolvedPrincipal", "Unknown test account")
            }
        }
        func groupID(named name: String) throws -> UInt32 {
            guard name == "staff" else { throw TractandaError("unresolvedPrincipal", "Unknown test group") }
            return 71001
        }
    }
    final class Fixture {
        let root: URL
        let accounts = Accounts()
        var revisions: [Revision] = []
        var originals: [String: Data] = [:]
        var permissions: [String: UInt32] = [:]
        var limits = InitialAuthorityBootstrap.Limits()
        init(directory: URL? = nil) throws {
            var fs = statvfs()
            let temp = try GuardedFixtureDirectory.parent()
            guard statvfs(temp.path, &fs) == 0, fs.f_frsize > 0,
                UInt64(fs.f_bavail) * UInt64(fs.f_frsize) >= 10 * 1024 * 1024 * 1024 + 32 * 1024 * 1024
            else { throw TractandaError("resourceLimit", "Tiny fixture requires genuine10GiB+32MiB reserve.") }
            root = directory ?? temp.appendingPathComponent("tractanda-first-source-dev-" + Identifier.make())
            limits.maximumRecords = 16; limits.maximumBytes = 1024 * 1024; limits.maximumWork = 128
            do { _ = try ItemStore(root: root, accounts: accounts) }
            // Real format1 originals with canonical paths. Never rewrite a fixture StoreID/ReplicaID.
            let item = try Self.id()
            let first = try Self.id(), second = try Self.id()
            var fields: [String: ItemValue] = ["itemID": .text(item), "revisionID": .text(first),
                "classID": .text("Item"), "schemaVersion": .integer(1),
                "createdAt": .date("2020-01-02T03:04:00.000Z"), "modifiedAt": .date("2020-01-02T03:04:00.000Z"),
                "actor": .text("uid:\(tractanda_uid())"), "operationID": .text("legacy-create"),
                "requestIdentity": .text(try JSON.encode(CommitRequest(classID: "Item",
                    changes: ["subject": .text("original")], operationID: "legacy-create")).base64EncodedString()),
                "subject": .text("original"), "permissions": .object([
                    "profile": .text(ItemPermissions.profile), "owner": .text("alice"),
                    "group": .text("staff"), "mode": .integer(0o600), "acl": .object([:])])]
            revisions.append(try Revision(fields: fields))
            fields["revisionID"] = .text(second); fields["supersedes"] = .text(first)
            fields["operationID"] = .text("legacy-revise"); fields["subject"] = .text("current")
            fields["requestIdentity"] = .text(try JSON.encode(CommitRequest(action: .revise,
                itemID: item, expectedRevisionID: first, changes: ["subject": .text("current")],
                operationID: "legacy-revise")).base64EncodedString())
            fields["modifiedAt"] = .date("2020-01-02T03:05:00.000Z")
            revisions.append(try Revision(fields: fields))
            for (offset, revision) in revisions.enumerated() {
                let path = "items/2020/01/02/03/0\(4 + offset)/\(item)/\(revision.revisionID).tractanda"
                let file = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                let bytes = try RecordCodec.encode(revision)
                try bytes.write(to: file)
                try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
                originals[path] = bytes; permissions[path] = try FileMetadata.read(at: file).mode
            }
            try StoreCheckpoint.markDirty(root: root)
            do {
                let store = try ItemStore(root: root, accounts: accounts, revisionProjectionEnabled: true)
                _ = try store.configureAccess(.object(["profile": .text(AccessConfiguration.profile),
                    "users": .list([.text("admin"), .text("alice"), .text("bob")]),
                    "administration": .text("system"), "administratorGroup": .text("staff")]), operationID: "policy")
            }
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        static func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }
        func run(_ operation: String, actorUID: UInt32? = nil, progress: ((String) throws -> Void)? = nil) throws {
            try DevelopmentFirstSourceConversion.run(root: root, accounts: accounts,
                actorUID: actorUID ?? tractanda_uid(), operationID: operation, limits: limits, progress: progress)
        }
        func open() throws -> ItemStore {
            try ItemStore(root: root, accounts: accounts, revisionProjectionEnabled: true, authorityIntakeEnabled: true)
        }
        func assertOriginals(file: StaticString = #filePath, line: UInt = #line) throws {
            var total: UInt64 = 0
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            for case let path as URL in enumerator {
                let metadata = try FileMetadata.read(at: path)
                if metadata.type == .regular { total += metadata.size }
                guard total <= 32 * 1024 * 1024 else { throw TractandaError("resourceLimit", "Tiny fixture32MiBcap") }
            }
            for (path, bytes) in originals {
                XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), bytes, file: file, line: line)
                XCTAssertEqual(try FileMetadata.read(at: root.appendingPathComponent(path)).mode, permissions[path], file: file, line: line)
            }
        }
    }
    func testLegacyConversionPreservesOriginalHistoryPermissionsPolicyAndNextWrite() throws {
        let root = try GuardedFixtureDirectory.create(prefix: "d", source: "DevelopmentFirstSourceFixtureTests", test: name)
        let f = try Fixture(directory: root); let operation = try Fixture.id()
        let storeIdentity = try InitialAuthorityBootstrap.storeIdentityBytes(root: f.root)
        let replica = try Data(contentsOf: f.root.appendingPathComponent(ReplicaIdentity.name))
        try f.run(operation)
        let request = try XCTUnwrap(InitialAuthorityBootstrap.load(root: f.root))
        for package in request.inventory!.originals.map(\.packageID) + request.pages.map(\.packageID) + [request.packageID] {
            let path = f.root.appendingPathComponent("authority/intake/" + package)
            XCTAssertEqual(try Data(contentsOf: path.appendingPathComponent("applied.json")),
                try Data(contentsOf: path.appendingPathComponent("sealed.json")))
        }
        try f.assertOriginals()
        XCTAssertEqual(try InitialAuthorityBootstrap.storeIdentityBytes(root: f.root), storeIdentity)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent(ReplicaIdentity.name)), replica)
        let store = try f.open()
        XCTAssertEqual(try store.history(f.revisions[0].itemID).count, 2)
        XCTAssertEqual(try store.withAccess(forUID: f.accounts.alice) { try store.get(f.revisions[0].itemID) }, f.revisions[1])
        XCTAssertThrowsError(try store.withAccess(forUID: f.accounts.bob) { try store.get(f.revisions[0].itemID) })
        _ = try store.withAccess(forUID: f.accounts.alice) {
            try store.commit(.init(action: .revise, itemID: f.revisions[0].itemID,
                expectedRevisionID: f.revisions[1].revisionID, changes: ["subject": .text("next")], operationID: "next"))
        }
    }
    func testConversionInterruptedBeforeAndAfterPinRetriesSameIDsAfterIndexLoss() throws {
        for boundary in ["retain", "beforePin", "afterPin"] {
            let f = try Fixture(); let operation = try Fixture.id()
            XCTAssertThrowsError(try f.run(operation) { if $0 == boundary { throw CancellationError() } })
            let request = try XCTUnwrap(InitialAuthorityBootstrap.load(root: f.root))
            XCTAssertThrowsError(try f.open())
            XCTAssertThrowsError(try f.run(Fixture.id()))
            try FileManager.default.removeItem(at: f.root.appendingPathComponent("index"))
            try f.run(operation)
            XCTAssertEqual(try InitialAuthorityBootstrap.load(root: f.root), request)
            try f.assertOriginals()
            let store = try f.open()
            XCTAssertEqual(try store.history(f.revisions[0].itemID).count, 2)
        }
    }
    func testCapturedSealedHistoryStaysPendingBeforePinAndMissingProofFailsColdRecovery() throws {
        let f = try Fixture(); let operation = try Fixture.id()
        XCTAssertThrowsError(try f.run(operation) { if $0 == "beforePin" { throw CancellationError() } })
        let request = try XCTUnwrap(InitialAuthorityBootstrap.load(root: f.root))
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("index"))
        var reopened: ItemStore? = try ItemStore(root: f.root, accounts: f.accounts,
            revisionProjectionEnabled: true, authorityIntakeEnabled: true, firstSourceOperation: request)
        XCTAssertThrowsError(try reopened!.withAccess(forUID: f.accounts.alice) {
            try reopened!.get(f.revisions[0].itemID)
        })
        reopened = nil
        do {
            let catalogue = try ItemIndex(path: f.root.appendingPathComponent("index/items.sqlite").path, create: false)
            defer { try? catalogue.closeChecked() }
            for original in request.inventory!.originals {
                let state = try catalogue.authorityDisposition(id: original.revisionID)?.disposition
                XCTAssertNotEqual(state, .eligible)
            }
        }
        // A local sealed receipt alone is not authored testimony or initial admission.
        let proof = f.root.appendingPathComponent("authority/initial-history/" + f.revisions[0].revisionID)
        try FileManager.default.removeItem(at: proof)
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("index"))
        XCTAssertThrowsError(try ItemStore(root: f.root, accounts: f.accounts,
            revisionProjectionEnabled: true, authorityIntakeEnabled: true, firstSourceOperation: request))
        XCTAssertFalse(try InitialAuthorityBootstrap.completed(root: f.root, request: request))
        try f.assertOriginals()
    }
    func testUnauthorizedAndTotalLimitedConversionDoesNotCaptureAuthority() throws {
        let f = try Fixture()
        XCTAssertThrowsError(try f.run(Fixture.id(), actorUID: f.accounts.alice))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".authority-initial-capture.json").path))
        f.limits.maximumRecords = 1
        XCTAssertThrowsError(try f.run(Fixture.id())) { XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit") }
        XCTAssertNil(try InitialAuthorityBootstrap.load(root: f.root))
        try f.assertOriginals()
    }
    func testAdministratorRevokedBeforeCaptureOrBeforeCompletionStaysPending() throws {
        for boundary in ["beforeAuthorityOpen", "beforeComplete"] {
            let f = try Fixture(); let operation = try Fixture.id()
            // Tests normally run as nonroot; root has an intentional repair bypass.
            guard tractanda_uid() != 0 else { throw XCTSkip("Root is always an authorized system-policy repair actor.") }
            XCTAssertThrowsError(try f.run(operation) { phase in
                if phase == boundary { f.accounts.administrator = false }
            }) { XCTAssertEqual(($0 as? TractandaError)?.code, "forbidden") }
            let request = try XCTUnwrap(InitialAuthorityBootstrap.load(root: f.root))
            XCTAssertFalse(try InitialAuthorityBootstrap.completed(root: f.root, request: request))
            if boundary == "beforeAuthorityOpen" {
                XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".authority-initial-capture.json").path))
            }
            f.accounts.administrator = true
            try f.run(operation)
        }
    }
    func testSameOriginModernConversionExportsCompleteApprovedBaseline() throws {
        let f = try Fixture()
        let modern: Revision
        do {
            let standalone = try ItemStore(root: f.root, accounts: f.accounts, revisionProjectionEnabled: true)
            modern = try standalone.withAccess(forUID: f.accounts.alice) {
                try standalone.commit(.init(classID: "Item", changes: ["subject": .text("modern before authority"),
                    "permissions": .object(["profile": .text(ItemPermissions.profile), "owner": .text("alice"),
                        "group": .text("staff"), "mode": .integer(0o600), "acl": .object([:])])],
                    operationID: "modern-standalone")).revision
            }
            XCTAssertEqual(modern.formatVersion, 2)
            let original = try XCTUnwrap(standalone.exportCatalogueForVerification().first { $0.revisionID == modern.revisionID })
            f.originals[original.path] = try Data(contentsOf: f.root.appendingPathComponent(original.path))
            f.permissions[original.path] = try FileMetadata.read(at: f.root.appendingPathComponent(original.path)).mode
        }
        let storeID = try CanonicalReaderRequirement.storeIdentity(root: f.root, ownerUID: tractanda_uid())
        let replica = try XCTUnwrap(ReplicaIdentity.load(root: f.root, storeID: storeID, ownerUID: tractanda_uid()))
        XCTAssertEqual(try modern.provenance?.originReplicaID, replica.replicaID)
        let operation = try Fixture.id()
        XCTAssertThrowsError(try f.run(operation) { if $0 == "beforePin" { throw CancellationError() } })
        let initialization = try XCTUnwrap(InitialAuthorityBootstrap.load(root: f.root))
        XCTAssertTrue(initialization.inventory!.originals.contains { $0.revisionID == modern.revisionID })
        do {
            let pending = try ItemStore(root: f.root, accounts: f.accounts,
                revisionProjectionEnabled: true, authorityIntakeEnabled: true, firstSourceOperation: initialization)
            XCTAssertThrowsError(try pending.withAccess(forUID: f.accounts.alice) { try pending.get(modern.itemID) })
        }
        do {
            let catalogue = try ItemIndex(path: f.root.appendingPathComponent("index/items.sqlite").path, create: false)
            defer { try? catalogue.closeChecked() }
            for original in initialization.inventory!.originals {
                XCTAssertNotEqual(try catalogue.authorityDisposition(id: original.revisionID)?.disposition, .eligible)
            }
        }
        try f.run(operation)
        try f.assertOriginals()
        let source = try ItemStore.openInitialized(root: f.root, accounts: f.accounts)
        XCTAssertEqual(try source.withAccess(forUID: f.accounts.alice) { try source.get(modern.itemID).revisionID }, modern.revisionID)
        let target = f.root.appendingPathComponent("prepared-target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let preparation = try PeerEnrollment.prepareTarget(root: target, commonStoreID: storeID, sourceReplicaID: replica.replicaID)
        let local = try PeerPackage.Context(peerID: "new-modern-target", storeID: storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("modern-source".utf8)), permittedOrigins: [preparation.targetReplicaID])
        let remote = try PeerPackage.Context(peerID: "modern-source", storeID: storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("modern-target".utf8)), permittedOrigins: [replica.replicaID])
        let pairing = try Fixture.id()
        let request = try PeerEnrollmentApproval.Request(operationID: Fixture.id(), preparationBytes: JSON.encode(preparation),
            sourceContext: local, targetContext: remote,
            sourceCredential: .init(binding: .init(peerID: local.peerID, storeID: storeID, localReplicaID: replica.replicaID,
                remoteReplicaID: preparation.targetReplicaID, pairingID: pairing, localIsInitiator: true,
                configurationDigest: local.configurationDigest), secret: Array(repeating: 31, count: 32)),
            targetCredential: .init(binding: .init(peerID: remote.peerID, storeID: storeID,
                localReplicaID: preparation.targetReplicaID, remoteReplicaID: replica.replicaID, pairingID: pairing,
                localIsInitiator: false, configurationDigest: remote.configurationDigest), secret: Array(repeating: 31, count: 32)))
        let handle = try source.beginPeerEnrollment(request, forUID: tractanda_uid())
        var manifest: PeerPackage.Manifest?
        for _ in 0..<128 {
            try f.assertOriginals()
            do { manifest = try source.stepPeerEnrollment(handle, forUID: tractanda_uid()).manifest }
            catch {
                throw TractandaError("modernBaselineDiagnostic", String(describing: error)
                    + " modernID=" + modern.revisionID + " validSourceOrigin=" + replica.replicaID)
            }
            if manifest != nil { break }
        }
        let baseline = try XCTUnwrap(manifest, "Tiny modern conversion baseline must close without omitting captured history")
        _ = try source.acceptPeerEnrollment(handle, forUID: tractanda_uid())
        var pending = [baseline.root], seen: Set<String> = []
        var modernDescriptor: PeerPackage.Object?
        var fabricatedEvidence = false
        while let object = pending.popLast() {
            if !seen.insert(object.id).inserted { continue }
            try f.assertOriginals()
            let bytes = try source.readPeerEnrollment(handle, object: object, offset: 0, forUID: tractanda_uid()).bytes
            XCTAssertEqual(bytes.count, object.length)
            if object.id == modern.revisionID {
                XCTAssertEqual(try RecordCodec.decode(bytes), modern)
                modernDescriptor = object
            }
            if object.kind == .authority {
                let record = try AuthorityRecordCodec.decode(bytes).record
                if record.kind == .authoredEvidence,
                    try AuthorityRecord.binding(record.payload["target"]).revisionID == modern.revisionID {
                    fabricatedEvidence = true
                }
            }
            if object.kind == .index {
                let page = try PeerPackage.decode(PeerPackage.Page.self, bytes)
                pending.append(contentsOf: page.objects + page.children)
            }
        }
        XCTAssertTrue(Set(initialization.inventory!.originals.map(\.revisionID)).isSubset(of: seen))
        XCTAssertTrue(seen.contains(modern.revisionID))
        XCTAssertFalse(fabricatedEvidence, "Historical initial admission must not fabricate authored testimony")
        XCTAssertTrue(seen.contains(initialization.rootID))
        try source.withAccess(forUID: tractanda_uid()) { try source.rebuildIndex() }
        XCTAssertEqual(try source.finishAcceptedPeerEnrollment(handle).manifest?.root, baseline.root)
        let restoredBytes = try source.readPeerEnrollment(handle, object: XCTUnwrap(modernDescriptor), offset: 0, forUID: tractanda_uid()).bytes
        XCTAssertEqual(try RecordCodec.decode(restoredBytes), modern)
        XCTAssertEqual(try ReplicaIdentity.load(root: f.root, storeID: storeID, ownerUID: tractanda_uid()), replica)
        try f.assertOriginals()
    }
    func testCanonicalInitialMembershipRejectsForgedLocatorAndMissingPage() throws {
        let f = try Fixture()
        try f.run(Fixture.id())
        let initialization = try XCTUnwrap(InitialAuthorityBootstrap.load(root: f.root))
        let outside: Revision
        do {
            let source = try f.open()
            outside = try source.commit(.init(classID: "Item", changes: ["subject": .text("outside initial history")],
                operationID: "outside-initial-history")).revision
        }
        let storeID = try CanonicalReaderRequirement.storeIdentity(root: f.root, ownerUID: tractanda_uid())
        let coordinator = PeerIntakeCoordinator(root: f.root, ownerUID: tractanda_uid(), storeID: storeID)
        let index = try ItemIndex(path: f.root.appendingPathComponent("index/items.sqlite").path, create: false)
        defer { try? index.closeChecked() }
        let configuration = try XCTUnwrap(coordinator.configuration())
        let pin = try XCTUnwrap(configuration.bootstrap)
        let captured = try XCTUnwrap(initialization.inventory!.originals.first { $0.currentAccessConfiguration })
        let capturedRow = try XCTUnwrap(index.retainedAuthorityObject(id: captured.revisionID))
        let capturedNode = try AuthorityRevision(originalBytes: coordinator.bytes(capturedRow))
        let outsideRow = try XCTUnwrap(index.retainedAuthorityObject(id: outside.revisionID))
        let outsideNode = try AuthorityRevision(originalBytes: coordinator.bytes(outsideRow))
        func membership(_ node: AuthorityRevision, maximumBytes: UInt64 = 32 * 1024 * 1024) throws -> AuthorityBinding? {
            var remaining = maximumBytes
            return try PeerInventory.canonicalInitialPin(node, coordinator: coordinator, index: index,
                proof: .init(), read: { row in
                    try f.assertOriginals()
                    try row.descriptor.validate()
                    guard UInt64(row.descriptor.length) <= remaining else { throw TractandaError("resourceLimit", "Tiny proof read cap") }
                    remaining -= UInt64(row.descriptor.length)
                    return try coordinator.bytes(row)
                }, charge: { count in
                    guard count >= 0, UInt64(count) <= remaining else { throw TractandaError("resourceLimit", "Tiny metadata proof read cap") }
                    remaining -= UInt64(count)
                })
        }
        XCTAssertNotNil(try membership(capturedNode))
        XCTAssertThrowsError(try membership(capturedNode, maximumBytes: 1)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
        }
        XCTAssertNil(try membership(outsideNode))
        let pageID = try XCTUnwrap(initialization.pages.first).recordID
        try index.execute("INSERT OR IGNORE INTO authority_dependencies VALUES(?,'bootstrap',?,?,'')",
            [outside.revisionID, pin.recordID, pin.sha256])
        try index.execute("INSERT OR IGNORE INTO authority_dependencies VALUES(?,'bootstrapMember',?,?,'')",
            [pageID, outside.revisionID, outsideNode.sha256])
        XCTAssertNotNil(try index.peerInventoryLegacyPin(revisionID: outside.revisionID, sha256: outsideNode.sha256),
            "The forged disposable locator must actually be exercised")
        XCTAssertNil(try membership(outsideNode), "A locator cannot invent a canonical initial member")
        let pageRow = try XCTUnwrap(index.retainedAuthorityObject(id: pageID))
        let original = f.root.appendingPathComponent(pageRow.path)
        let saved = f.root.appendingPathComponent("saved-initial-page")
        try FileManager.default.moveItem(at: original, to: saved)
        defer { if FileManager.default.fileExists(atPath: saved.path) { try? FileManager.default.moveItem(at: saved, to: original) } }
        XCTAssertThrowsError(try membership(capturedNode), "Missing canonical page cannot be replaced by derived edges")
        try FileManager.default.moveItem(at: saved, to: original)
        XCTAssertNotNil(try membership(capturedNode))
        try f.assertOriginals()
    }
    func testModernMissingOrReplacedIdentityFailsClosed() throws {
        let f = try Fixture(); let operation = try Fixture.id()
        let identity = f.root.appendingPathComponent(ReplicaIdentity.name)
        try FileManager.default.removeItem(at: identity)
        XCTAssertThrowsError(try f.run(operation))
        XCTAssertNil(try InitialAuthorityBootstrap.load(root: f.root))
        let g = try Fixture(); let other = try Fixture.id()
        XCTAssertThrowsError(try g.run(other) { if $0 == "beforeAuthorityOpen" { throw CancellationError() } })
        let actual = try XCTUnwrap(InitialAuthorityBootstrap.load(root: g.root)?.inventory?.replicaIdentity)
        let changed = try JSON.decode(ReplicaIdentity.Record.self, actual)
        try FileManager.default.removeItem(at: g.root.appendingPathComponent(ReplicaIdentity.name))
        try DocumentContentFiles(root: g.root, ownerUID: tractanda_uid(), minimumFreeBytes: 0).writeImmutable(
            JSON.encode(ReplicaIdentity.Record(formatVersion: 1, storeID: changed.storeID, replicaID: Fixture.id())),
            path: [ReplicaIdentity.name], maximumBytes: 4096)
        XCTAssertThrowsError(try g.run(other))
        XCTAssertFalse(FileManager.default.fileExists(atPath: g.root.appendingPathComponent(".authority-initial-capture.json").path))
    }
}
