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
        func assertOriginals(maximumFixtureBytes: UInt64 = 32 * 1024 * 1024,
            file: StaticString = #filePath, line: UInt = #line) throws {
            var total: UInt64 = 0
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            for case let path as URL in enumerator {
                let metadata = try FileMetadata.read(at: path)
                if metadata.type == .regular { total += metadata.size }
                guard total <= maximumFixtureBytes else { throw TractandaError("resourceLimit", "Fixture byte cap exceeded") }
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
        // A real legacy store contains both owner-private writable and read-only originals.
        let writable = try XCTUnwrap(f.originals.keys.sorted().first)
        let writableURL = f.root.appendingPathComponent(writable)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: writableURL.path)
        f.permissions[writable] = try FileMetadata.read(at: writableURL).mode
        let storeIdentity = try InitialAuthorityBootstrap.storeIdentityBytes(root: f.root)
        let replica = try Data(contentsOf: f.root.appendingPathComponent(ReplicaIdentity.name))
        try f.run(operation)
        let request = try XCTUnwrap(InitialAuthorityBootstrap.load(root: f.root))
        XCTAssertEqual(request.inventory?.originals.first { $0.path == writable }?.mode,
            UInt32(S_IFREG) | 0o600)
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
    func testCanonicalOriginalReaderRejectsUnsafeCustodyChangedBytesAndSize() throws {
        let f = try Fixture()
        let path = try XCTUnwrap(f.originals.keys.sorted().first)
        let url = f.root.appendingPathComponent(path)
        let revision = try RecordCodec.decode(XCTUnwrap(f.originals[path]))
        func original(length: Int? = nil, uid: UInt32? = nil, digest: String? = nil)
            throws -> InitialAuthorityBootstrap.Original {
            let metadata = try FileMetadata.read(at: url)
            return .init(path: path, itemID: revision.itemID, revisionID: revision.revisionID,
                sha256: digest ?? AuthorityRecordCodec.sha256(f.originals[path]!),
                length: length ?? f.originals[path]!.count, currentAccessConfiguration: false,
                mode: metadata.mode, uid: uid ?? metadata.uid,
                packageID: try Fixture.id(), framingID: try Fixture.id())
        }
        XCTAssertEqual(try InitialAuthorityBootstrap.readOriginal(root: f.root, original: original()),
            f.originals[path])
        XCTAssertThrowsError(try InitialAuthorityBootstrap.readOriginal(root: f.root,
            original: original(uid: tractanda_uid() == 0 ? 1 : 0)))
        for mode in [0o640, 0o604, 0o666] {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
            // Even a receipt matching the unsafe mode must not authorize it.
            XCTAssertThrowsError(try InitialAuthorityBootstrap.readOriginal(root: f.root, original: original()))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let object = PeerPackage.Object(kind: .item, id: revision.revisionID,
            length: f.originals[path]!.count, sha256: AuthorityRecordCodec.sha256(f.originals[path]!))
        XCTAssertEqual(try InitialAuthorityBootstrap.retainedItemBytes(root: f.root, path: path,
            object: object, ownerUID: tractanda_uid()), f.originals[path])
        XCTAssertThrowsError(try InitialAuthorityBootstrap.retainedItemBytes(root: f.root, path: path,
            object: object, ownerUID: tractanda_uid() == 0 ? 1 : 0))
        let coordinator = PeerIntakeCoordinator(root: f.root, ownerUID: tractanda_uid(),
            storeID: try Fixture.id())
        let retained = AuthorityStore.RetainedObject(descriptor: object, path: path,
            packageID: try Fixture.id(), peerID: "local", configurationDigest: object.sha256,
            permittedOrigin: true)
        try coordinator.withOperation(maximumReadBytes: UInt64(object.length)) {
            XCTAssertEqual(try coordinator.retainedCanonicalItemBytes(retained), f.originals[path])
            XCTAssertEqual(coordinator.operationReadBytesForTesting, UInt64(object.length),
                "Promotion recheck charges its actual canonical hydration exactly once")
        }
        try coordinator.withOperation(maximumReadBytes: UInt64(object.length - 1)) {
            XCTAssertThrowsError(try coordinator.retainedCanonicalItemBytes(retained)) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
            }
            XCTAssertEqual(coordinator.operationReadBytesForTesting, 0)
        }
        XCTAssertEqual(try Data(contentsOf: url), f.originals[path])
        XCTAssertEqual(try FileMetadata.read(at: url).mode & 0o777, 0o600)
        for length in [-1, 0, PooledCanonicalRecord.maximumRecordBytes + 1] {
            var charged = false
            let invalid = PeerPackage.Object(kind: .item, id: object.id, length: length, sha256: object.sha256)
            XCTAssertThrowsError(try InitialAuthorityBootstrap.retainedItemBytes(root: f.root, path: path,
                object: invalid, ownerUID: tractanda_uid(), readBudget: { _ in charged = true }))
            XCTAssertFalse(charged, "Invalid descriptors must fail before accounting")
        }
        XCTAssertThrowsError(try InitialAuthorityBootstrap.files(f.root).read(
            path: path.split(separator: "/").map(String.init), maximumBytes: object.length),
            "The document/metadata reader must retain its strict immutable permissions policy")
        XCTAssertThrowsError(try InitialAuthorityBootstrap.readOriginal(root: f.root,
            original: original(digest: String(repeating: "0", count: 64))))
        XCTAssertThrowsError(try InitialAuthorityBootstrap.readOriginal(root: f.root,
            original: original(length: PooledCanonicalRecord.maximumRecordBytes + 1)))
        let captured = try original()
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(PooledCanonicalRecord.maximumRecordBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try InitialAuthorityBootstrap.readOriginal(root: f.root, original: captured))
    }
    func testCanonicalOriginalReaderRejectsSymlinkFileAndDirectory() throws {
        let f = try Fixture()
        let path = try XCTUnwrap(f.originals.keys.sorted().first)
        let url = f.root.appendingPathComponent(path)
        let revision = try RecordCodec.decode(XCTUnwrap(f.originals[path]))
        let metadata = try FileMetadata.read(at: url)
        let original = InitialAuthorityBootstrap.Original(path: path,
            itemID: revision.itemID, revisionID: revision.revisionID,
            sha256: AuthorityRecordCodec.sha256(f.originals[path]!), length: f.originals[path]!.count,
            currentAccessConfiguration: false, mode: metadata.mode, uid: metadata.uid,
            packageID: try Fixture.id(), framingID: try Fixture.id())
        let saved = url.appendingPathExtension("saved")
        try FileManager.default.moveItem(at: url, to: saved)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: saved)
        XCTAssertThrowsError(try InitialAuthorityBootstrap.readOriginal(root: f.root, original: original))
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: saved, to: url)
        let directory = url.deletingLastPathComponent()
        let savedDirectory = directory.appendingPathExtension("saved")
        try FileManager.default.moveItem(at: directory, to: savedDirectory)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: savedDirectory)
        XCTAssertThrowsError(try InitialAuthorityBootstrap.readOriginal(root: f.root, original: original))
    }
    func testBootstrapPackingUsesCompleteEnvelopeAndPreservesPending1943Allocations() throws {
        let storeID = try Fixture.id(), replicaID = try Fixture.id(), itemID = try Fixture.id()
        let originals = try (0..<1943).map { _ -> InitialAuthorityBootstrap.Original in
            let revision = try Fixture.id()
            return .init(path: "items/2020/01/02/03/04/\(itemID)/\(revision).tractanda",
                itemID: itemID, revisionID: revision, sha256: String(repeating: "0", count: 64),
                length: 1, currentAccessConfiguration: false, mode: UInt32(S_IFREG) | 0o600,
                uid: tractanda_uid(), packageID: try Fixture.id(), framingID: try Fixture.id())
        }.sorted { $0.revisionID < $1.revisionID }
        let entries: [ItemValue] = try originals.map { original in
            .object(["target": try AuthorityStore.Target(itemID: original.itemID,
                revisionID: original.revisionID, sha256: original.sha256).itemValue,
                "frontier": .list([.text(original.revisionID)])])
        }.sorted { $0.map!["target"]!.map!["revisionID"]!.string! < $1.map!["target"]!.map!["revisionID"]!.string! }
        let inventory = InitialAuthorityBootstrap.Inventory(
            storeIdentity: try JSONSerialization.data(withJSONObject: ["storeID": storeID]),
            replicaIdentity: try JSON.encode(ReplicaIdentity.Record(formatVersion: 1,
                storeID: storeID, replicaID: replicaID)), originals: originals)
        func request(_ count: Int) throws -> InitialAuthorityBootstrap.Request {
            try .make(operationID: Fixture.id(), actorUID: tractanda_uid(), policy: nil,
                inventory: .init(storeIdentity: inventory.storeIdentity, replicaIdentity: inventory.replicaIdentity,
                    originals: Array(originals.prefix(count))), actor: "rcfa",
                conversionEntries: Array(entries.prefix(count)))
        }
        let pending = try request(1943)
        XCTAssertEqual(pending.pages.count, 16, "The real pending allocation count can be reused exactly")
        let before = try JSON.encode(pending)
        let records = try InitialAuthorityBootstrap.records(entries: entries, policies: [], request: pending,
            storeID: storeID, origin: replicaID, actor: pending.actor)
        let bytes = try records.map(AuthorityRecordCodec.encode)
        XCTAssertTrue(bytes.allSatisfy { $0.count <= AuthorityRecord.maximumBytes })
        print("BootstrapPackingSwiftEvidence originals=1943 allocations=\(pending.pages.count) "
            + "records=\(records.count) maximumEnvelopeBytes=\(bytes.map(\.count).max()!) cap=\(AuthorityRecord.maximumBytes)")
        XCTAssertEqual(records.filter { $0.kind == .bootstrapPage }.reduce(0) {
            $0 + ($1.payload["entries"]?.array?.count ?? 0)
        }, 1943)
        XCTAssertEqual(try InitialAuthorityBootstrap.records(entries: entries, policies: [], request: pending,
            storeID: storeID, origin: replicaID, actor: pending.actor).map(AuthorityRecordCodec.encode), bytes)
        XCTAssertEqual(try JSON.encode(pending), before, "Retry does not rewrite the pending request/IDs/hash")
        for count in [128, 129] {
            let small = try request(count)
            XCTAssertEqual(small.pages.count, 2, "Count-only128 packing exceeds the actual pretty envelope")
            let records = try InitialAuthorityBootstrap.records(entries: Array(entries.prefix(count)), policies: [],
                request: small, storeID: storeID, origin: replicaID, actor: small.actor)
            XCTAssertTrue(try records.map(AuthorityRecordCodec.encode).allSatisfy { $0.count <= AuthorityRecord.maximumBytes })
        }
        XCTAssertThrowsError(try AuthorityRecord(recordID: Fixture.id(), storeID: storeID,
            originReplicaID: replicaID, kind: .bootstrapPage, actorPrincipal: "rcfa", createdAt: pending.createdAt,
            payload: ["manifestID": .text(pending.rootID), "entries": .list(Array(entries.prefix(128)))])) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit",
                "The old full128 page fails the actual Swift encoder, not a modeled size")
        }
    }
    func testBootstrapPackingSplitsLargeFrontiersAndRejectsAnOversizedEntry() throws {
        let id = try Fixture.id()
        func entry(_ frontierCount: Int) throws -> ItemValue {
            .object(["target": try AuthorityStore.Target(itemID: id, revisionID: Fixture.id(),
                sha256: String(repeating: "0", count: 64)).itemValue,
                "frontier": .list(try (0..<frontierCount).map { _ in .text(try Fixture.id()) })])
        }
        func groups(_ entries: [ItemValue]) throws -> [[ItemValue]] {
            try InitialAuthorityBootstrap.pageGroups(entries: entries, placeholderID: id, manifestID: id,
                storeID: id, origin: id, actor: "rcfa", createdAt: Timestamp.now())
        }
        let larger = try (0..<128).map { _ in try entry(16) }
        XCTAssertGreaterThan(try groups(larger).count, 2, "Frontier width also consumes the byte budget")
        XCTAssertThrowsError(try groups([entry(1024)])) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
        }
    }
    func test129OriginalConversionRetryPreservesItsExactPendingReceipt() throws {
        let f = try Fixture()
        f.limits.maximumRecords = 256
        f.limits.maximumWork = 1024
        let additionalEstimate = 126 * ((try RecordCodec.encode(f.revisions[0])).count + 128)
        guard additionalEstimate < f.limits.maximumBytes / 2 else {
            throw TractandaError("resourceLimit", "Tiny129-original fixture estimate exceeds its bound.")
        }
        for offset in 0..<126 {
            if offset % 16 == 0 {
                try InitialAuthorityBootstrap.capacity(root: f.root, limits: f.limits)
                try f.assertOriginals()
            }
            var fields = f.revisions[0].fields
            let item = try Fixture.id(), revision = try Fixture.id()
            let operation = "legacy-packing-\(offset)"
            fields["itemID"] = .text(item); fields["revisionID"] = .text(revision)
            fields["operationID"] = .text(operation)
            fields["requestIdentity"] = .text(try JSON.encode(CommitRequest(classID: "Item",
                changes: ["subject": .text("original")], operationID: operation)).base64EncodedString())
            let bytes = try RecordCodec.encode(Revision(fields: fields))
            let path = "items/2020/01/02/03/04/\(item)/\(revision).tractanda"
            let url = f.root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try bytes.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            f.originals[path] = bytes; f.permissions[path] = try FileMetadata.read(at: url).mode
        }
        try StoreCheckpoint.markDirty(root: f.root)
        let operation = try Fixture.id()
        XCTAssertThrowsError(try f.run(operation) {
            if $0 == "beforeAuthorityOpen" { throw CancellationError() }
        })
        let pending = try XCTUnwrap(InitialAuthorityBootstrap.load(root: f.root))
        XCTAssertEqual(pending.inventory?.originals.count, 129)
        XCTAssertEqual(pending.pages.count, 2)
        let receipt = try Data(contentsOf: f.root.appendingPathComponent(InitialAuthorityBootstrap.receiptName))
        try f.run(operation)
        XCTAssertTrue(try InitialAuthorityBootstrap.completed(root: f.root, request: pending))
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent(InitialAuthorityBootstrap.receiptName)), receipt)
        try f.assertOriginals()
        let store = try f.open()
        XCTAssertEqual(try store.history(f.revisions[0].itemID).count, 2)
    }
    func testBoundedConversionScalingMeasurement() throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["TRACTANDA_CONVERSION_MEASUREMENT_COUNT"], let count = Int(raw),
            [129, 257, 513].contains(count), let output = env["TRACTANDA_SCALING_RESULT"]
        else { throw XCTSkip("Explicit bounded conversion measurement is not requested.") }
        let setupStarted = ProcessInfo.processInfo.systemUptime
        let f = try Fixture()
        f.limits.maximumRecords = 1024; f.limits.maximumWork = 4096
        f.limits.maximumBytes = 4 * 1024 * 1024
        let cap: UInt64 = 128 * 1024 * 1024
        let retainedEstimate = UInt64(8 * 1024 * 1024 + count * 160 * 1024)
        guard retainedEstimate <= cap,
            (count - 3) * ((try RecordCodec.encode(f.revisions[0])).count + 128) < f.limits.maximumBytes
        else { throw TractandaError("resourceLimit", "Measurement estimate exceeds its admitted bounds.") }
        var guardSeconds = 0.0
        func capacity() throws {
            let start = ProcessInfo.processInfo.systemUptime
            var info = statvfs()
            guard statvfs(f.root.path, &info) == 0, info.f_frsize > 0 else {
                throw TractandaError("resourceLimit", "Cannot inspect measurement fixture capacity.")
            }
            let available = UInt64(info.f_bavail).multipliedReportingOverflow(by: UInt64(info.f_frsize))
            guard !available.overflow, available.partialValue >= 10 * 1024 * 1024 * 1024 + retainedEstimate else {
                throw TractandaError("resourceLimit", "Measurement requires genuine10GiB reserve plus estimate.")
            }
            try f.assertOriginals(maximumFixtureBytes: cap)
            guardSeconds += ProcessInfo.processInfo.systemUptime - start
        }
        try capacity()
        for offset in 0..<(count - 3) {
            if offset % 16 == 0 { try capacity() }
            var fields = f.revisions[0].fields
            let item = try Fixture.id(), revision = try Fixture.id()
            let operation = "legacy-scaling-\(offset)"
            fields["itemID"] = .text(item); fields["revisionID"] = .text(revision)
            fields["operationID"] = .text(operation)
            fields["requestIdentity"] = .text(try JSON.encode(CommitRequest(classID: "Item",
                changes: ["subject": .text("original")], operationID: operation)).base64EncodedString())
            let bytes = try RecordCodec.encode(Revision(fields: fields))
            let path = "items/2020/01/02/03/04/\(item)/\(revision).tractanda"
            let url = f.root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try bytes.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            f.originals[path] = bytes; f.permissions[path] = try FileMetadata.read(at: url).mode
        }
        try capacity()
        try StoreCheckpoint.markDirty(root: f.root)
        let setupSeconds = ProcessInfo.processInfo.systemUptime - setupStarted
        let started = ProcessInfo.processInfo.systemUptime
        let initialGuardSeconds = guardSeconds
        var phase = "preflight", phaseStarted = started, retained = 0
        var phases: [String: Double] = [:]
        func resourceState() -> [String: Any] {
            var usage = rusage()
            #if canImport(Darwin)
                let status = getrusage(RUSAGE_SELF, &usage)
                let peak = Int64(usage.ru_maxrss)
            #else
                let status = getrusage(RUSAGE_SELF.rawValue, &usage)
                let peak = Int64(usage.ru_maxrss) * 1024
            #endif
            guard status == 0 else { return [:] }
            return ["cpuSeconds": Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000,
                "peakRSSBytes": peak]
        }
        func publish() throws {
            let now = ProcessInfo.processInfo.systemUptime
            var durations = phases
            durations[phase, default: 0] += now - phaseStarted
            var fact: [String: Any] = ["profile": "tractanda.scaling-measurement.v1", "kind": "conversion",
                "phase": phase, "pid": Int(getpid()), "uid": Int(getuid()), "fixtureRoot": f.root.path,
                "count": count, "retains": retained, "wallSeconds": now - started,
                "setupSeconds": setupSeconds, "guardSeconds": guardSeconds - initialGuardSeconds,
                "phaseSeconds": durations, "estimatedFixtureBytes": retainedEstimate]
            for (key, value) in resourceState() { fact[key] = value }
            try JSONSerialization.data(withJSONObject: fact, options: [.sortedKeys]).write(
                to: URL(fileURLWithPath: output), options: .atomic)
        }
        func progress(_ next: String) throws {
            let changed = next != phase
            if changed {
                let now = ProcessInfo.processInfo.systemUptime
                phases[phase, default: 0] += now - phaseStarted
                phase = next; phaseStarted = now
            }
            if next == "retain" { retained += 1 }
            if changed || (next == "retain" && retained % 64 == 0) {
                try capacity()
                try publish()
            }
        }
        try publish()
        let operation = try Fixture.id()
        XCTAssertThrowsError(try f.run(operation) {
            try progress($0)
            if $0 == "beforeAuthorityOpen" { throw CancellationError() }
        })
        let pending = try XCTUnwrap(InitialAuthorityBootstrap.load(root: f.root))
        XCTAssertEqual(pending.inventory?.originals.count, count)
        let receipt = try Data(contentsOf: f.root.appendingPathComponent(InitialAuthorityBootstrap.receiptName))
        let metadata = try Dictionary(uniqueKeysWithValues: pending.inventory!.originals.map {
            ($0.path, try FileMetadata.read(at: f.root.appendingPathComponent($0.path)))
        })
        try f.run(operation, progress: progress)
        XCTAssertTrue(try InitialAuthorityBootstrap.completed(root: f.root, request: pending))
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent(InitialAuthorityBootstrap.receiptName)), receipt)
        try capacity()
        for (path, original) in metadata {
            XCTAssertEqual(try FileMetadata.read(at: f.root.appendingPathComponent(path)), original)
        }
        do { let store = try f.open(); XCTAssertEqual(try store.history(f.revisions[0].itemID).count, 2) }
        try progress("complete")
        try publish()
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
