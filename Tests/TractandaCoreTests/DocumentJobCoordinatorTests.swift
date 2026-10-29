import CTractandaPlatform
import Crypto
import Foundation
import TractandaClient
import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

// Boundary-test fixture ownership only; no product API or shared runtime state.
enum GuardedFixtureDirectory {
    struct Context {
        let root: URL
        let proof: URL
    }
    static func physical(_ url: URL) throws -> URL {
        guard url.path.hasPrefix("/"), !url.path.contains("\0"),
            let path = realpath(url.path, nil)
        else { throw TractandaError("fixtureRoot", "Cannot resolve physical fixture path.") }
        defer { free(path) }
        // Foundation resolution can rewrite /private/var back to the symlink /var.
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }
    static func relativePath(_ url: URL, beneath root: URL) throws -> String {
        let prefix = root.path + "/"
        var info = stat()
        guard try physical(root).path == root.path,
            lstat(root.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
            info.st_uid == geteuid(), info.st_mode & 0o022 == 0,
            url.path.hasPrefix(prefix),
            try physical(url.deletingLastPathComponent()).path == url.deletingLastPathComponent().path
        else { throw TractandaError("fixtureRoot", "Enumerated fixture escaped its physical owned root.") }
        let relative = String(url.path.dropFirst(prefix.count))
        guard !relative.isEmpty,
            relative.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw TractandaError("fixtureRoot", "Invalid relative fixture path.") }
        return relative
    }
    static func validate(_ url: URL) throws -> stat {
        var info = stat()
        guard url.path.hasPrefix("/"), try physical(url).path == url.path,
            lstat(url.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
            info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700
        else {
            throw TractandaError(
                "fixtureRoot", "Fixture override must be an existing private owned physical directory.")
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
        let result = Context(
            root: URL(fileURLWithPath: root, isDirectory: true),
            proof: URL(fileURLWithPath: proof, isDirectory: true))
        guard root.hasPrefix("/"), proof.hasPrefix("/"), result.root.path == root,
            result.proof.path == proof, result.root.path != result.proof.path,
            result.root.deletingLastPathComponent().path == result.proof.deletingLastPathComponent().path,
            try validate(result.root).st_dev == validate(result.proof).st_dev
        else {
            throw TractandaError(
                "fixtureRoot", "Fixture and proof overrides must be physical sibling directories.")
        }
        return result
    }
    static func parent() throws -> URL {
        try context()?.root ?? physical(FileManager.default.temporaryDirectory)
    }
    static func create(prefix: String, source: String, test: String, socket: String? = nil) throws -> URL {
        let context = try context()
        let parent = try context?.root ?? physical(FileManager.default.temporaryDirectory)
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
                throw TractandaError(
                    "resourceLimit", "Configured fixture root leaves no room for a Unix socket.")
            }
        }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        if let context {
            let actual = try physical(root)
            _ = try validate(actual)
            guard actual.path == root.path, actual.deletingLastPathComponent().path == context.root.path,
                test.utf8.count <= 256
            else { throw TractandaError("fixtureRoot", "Fixture escaped its override.") }
            let fact: [String: Any] = [
                "profile": "tractanda.fixture-root-proof.v1", "source": source,
                "test": test, "root": actual.path, "expectedRoot": context.root.path,
                "proofRoot": context.proof.path, "uid": Int(geteuid()), "pid": Int(getpid()),
                "phase": "created",
            ]
            let bytes = try JSONSerialization.data(withJSONObject: fact, options: [.sortedKeys])
            guard bytes.count <= 2048 else {
                throw TractandaError("fixtureRoot", "Fixture proof exceeds its bound.")
            }
            let temporary = context.root.appendingPathComponent(
                ".fixture-proof-" + UUID().uuidString + ".tmp")
            let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw TractandaError("fixtureRoot", "Cannot create fixture proof.") }
            defer { _ = close(descriptor) }
            try bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < bytes.count {
                    let count = write(
                        descriptor, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else {
                        throw TractandaError("fixtureRoot", "Cannot write fixture proof.")
                    }
                    offset += count
                }
            }
            guard fsync(descriptor) == 0 else {
                throw TractandaError("fixtureRoot", "Cannot sync fixture proof.")
            }
            try FileManager.default.moveItem(
                at: temporary,
                to: context.proof.appendingPathComponent(source + "-" + root.lastPathComponent + ".json"))
            let directory = open(context.proof.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else {
                throw TractandaError("fixtureRoot", "Cannot open fixture proof directory.")
            }
            defer { _ = close(directory) }
            guard fsync(directory) == 0 else {
                throw TractandaError("fixtureRoot", "Cannot sync fixture proof directory.")
            }
        }
        return root
    }
}

final class DocumentJobCoordinatorTests: XCTestCase {
    private var publicationContentionForTesting: (() -> Void)?
    private struct Transport: TractandaClient.ItemTransport {
        let coordinator: ServiceCoordinator
        var uid: UInt32 = UInt32(getuid())
        func send(_ request: Data) async throws -> Data {
            try await coordinator.handle(request, forUID: uid)
        }
    }
    private struct Fixture {
        let root: URL
        let store: URL
        let configuration: DocumentConverterConfiguration
        let request: DocumentJobStart
    }
    private func capacity(_ root: URL, beforeMetadata: ((URL) throws -> Void)? = nil) throws {
        for attempt in 0..<3 {
            do {
                try capacityAttempt(root, beforeMetadata: beforeMetadata)
                return
            } catch {
                let failure = error as NSError
                let path = failure.userInfo[NSFilePathErrorKey] as? String
                guard attempt < 2, failure.domain == NSPOSIXErrorDomain, failure.code == ENOENT,
                    let path, operationalInventoryPath(path, root: root)
                else { throw error }
            }
        }
    }

    private func readerRequirementStage(_ url: URL, root: URL) -> Bool {
        let prefix = ".reader-requirement-"
        let suffix = ".stage"
        let name = url.lastPathComponent
        guard url.deletingLastPathComponent().path == root.appendingPathComponent("store").path,
            name.hasPrefix(prefix), name.hasSuffix(suffix)
        else { return false }
        let id = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        guard let uuid = UUID(uuidString: id) else { return false }
        return uuid.uuidString == id
    }

    private func operationalInventoryPath(_ path: String, root: URL) -> Bool {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        if readerRequirementStage(url, root: root) {
            // Its writer has no explicit encoded-size bound. Restart the complete
            // inventory rather than guessing a charge for a vanished stage.
            return true
        }
        let atomic =
            name.hasPrefix(".checkpoint-") && name.hasSuffix(".tmp")
            && UUID(uuidString: String(name.dropFirst(12).dropLast(4))) != nil
        let rebuildPrefix = "personal-rebuild-"
        let rebuildSuffix = ".sqlite-journal"
        if url.deletingLastPathComponent().path == root.appendingPathComponent("store/index").path,
            name.hasPrefix(rebuildPrefix), name.hasSuffix(rebuildSuffix)
        {
            let id = String(name.dropFirst(rebuildPrefix.count).dropLast(rebuildSuffix.count))
            if let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id {
                // SQLite DELETE journals can disappear during an active rebuild.
                // Restart the whole bounded inventory; never omit or zero-charge a file.
                return true
            }
        }
        if url.deletingLastPathComponent().path == root.appendingPathComponent("store").path {
            return name == ".tractanda-checkpoint-dirty" || atomic
        }
        let prefix = root.appendingPathComponent("store/document-jobs").path + "/"
        guard path.hasPrefix(prefix) else { return false }
        let parts = path.dropFirst(prefix.count).split(separator: "/").map(String.init)
        guard parts.count >= 3, UUID(uuidString: parts[0])?.version1Components != nil,
            parts[1] == "sessions", UUID(uuidString: parts[2])?.version1Components != nil
        else { return false }
        let dependency =
            name.hasPrefix(".dependency-") && name.hasSuffix(".tmp")
            && UUID(uuidString: String(name.dropFirst(12).dropLast(4))) != nil
        return parts.count == 3 || (parts.count == 4 && (parts[3] == "binding.json" || dependency))
    }

    private func capacityAttempt(_ root: URL, beforeMetadata: ((URL) throws -> Void)?) throws {
        var status = statvfs()
        guard statvfs(root.path, &status) == 0, status.f_frsize > 0 else {
            throw TractandaError("resourceLimit", "Cannot inspect genuine fixture capacity.")
        }
        let available = UInt64(status.f_bavail).multipliedReportingOverflow(by: UInt64(status.f_frsize))
        let cap: UInt64 = 16 * 1024 * 1024
        guard !available.overflow, available.partialValue >= 10 * 1024 * 1024 * 1024 + cap else {
            throw TractandaError("resourceLimit", "Fixture requires genuine 10 GiB reserve plus 16 MiB cap.")
        }
        guard root.lastPathComponent.hasPrefix("j") else { return }
        var owner = stat()
        guard lstat(root.path, &owner) == 0, owner.st_uid == getuid(),
            owner.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), owner.st_mode & 0o077 == 0
        else { throw TractandaError("resourceLimit", "Fixture accounting requires a private owned root.") }
        var bytes: UInt64 = 0
        func scan(_ directory: URL) throws {
            func visit(_ directory: URL) throws {
                try POSIXDirectory.withEntries(at: directory) { name in
                    let url = directory.appendingPathComponent(name)
                    try beforeMetadata?(url)
                    var entry = stat()
                    let exists = lstat(url.path, &entry) == 0
                    let failure = exists ? 0 : errno
                    if !exists && failure != ENOENT {
                        throw NSError(
                            domain: NSPOSIXErrorDomain, code: Int(failure),
                            userInfo: [NSFilePathErrorKey: url.path])
                    }
                    if exists, entry.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                        try scan(url)
                    } else if !exists, let promoted = try promotedEntry(url, root: root),
                        promoted.1.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
                    {
                        try scan(promoted.0)
                    } else {
                        bytes += try accountedBytes(url, root: root)
                    }
                    guard bytes <= cap else {
                        throw TractandaError("resourceLimit", "Fixture exceeded 16 MiB cap.")
                    }
                    return true
                }
            }
            do { try visit(directory) } catch FileMetadataError.posix(ENOENT) {
                guard let promoted = try promotedEntry(directory, root: root),
                    promoted.1.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
                else {
                    throw NSError(
                        domain: NSPOSIXErrorDomain, code: Int(ENOENT),
                        userInfo: [NSFilePathErrorKey: directory.path])
                }
                try visit(promoted.0)
            }
        }
        try scan(root)
    }

    func testOperationalInventoryRetryIsBoundedAndCanonicalLossIsNotRetried() throws {
        let root = try GuardedFixtureDirectory.create(
            prefix: "j", source: "DocumentJobCoordinatorTests", test: name)
        defer { try? FileManager.default.removeItem(at: root) }
        try capacity(root)
        let file = root.appendingPathComponent("probe")
        try Data([1]).write(to: file)
        let marker = root.appendingPathComponent("store/.tractanda-checkpoint-dirty").path
        var attempts = 0
        XCTAssertThrowsError(
            try capacity(root) { _ in
                attempts += 1
                throw NSError(
                    domain: NSPOSIXErrorDomain, code: Int(ENOENT), userInfo: [NSFilePathErrorKey: marker])
            })
        XCTAssertEqual(attempts, 3)
        let index = root.appendingPathComponent("store/index")
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
        let rebuildJournal = index.appendingPathComponent(
            "personal-rebuild-" + Identifier.make() + ".sqlite-journal")
        try Data([1]).write(to: rebuildJournal)
        var removedJournal = false
        try capacity(root) { url in
            if url.path == rebuildJournal.path, !removedJournal {
                try FileManager.default.removeItem(at: url)
                removedJournal = true
            }
        }
        XCTAssertTrue(removedJournal, "The enumerated transient journal must actually disappear")
        try Data([1]).write(to: rebuildJournal)
        let oversized = root.appendingPathComponent("oversized-after-retry")
        var introducedOversized = false
        XCTAssertThrowsError(
            try capacity(root) { url in
                if url.path == rebuildJournal.path, !introducedOversized {
                    try FileManager.default.removeItem(at: url)
                    let fd = open(oversized.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
                    guard fd >= 0 else { throw POSIXError(.EIO) }
                    defer { _ = close(fd) }
                    guard ftruncate(fd, 16 * 1024 * 1024 + 1) == 0 else { throw POSIXError(.EIO) }
                    introducedOversized = true
                }
            }
        ) { error in
            XCTAssertEqual((error as? TractandaError)?.code, "resourceLimit")
        }
        XCTAssertTrue(introducedOversized, "The retry must rescan and enforce the full cap")
        try FileManager.default.removeItem(at: oversized)
        attempts = 0
        XCTAssertThrowsError(
            try capacity(root) { _ in
                attempts += 1
                throw NSError(
                    domain: NSPOSIXErrorDomain, code: Int(ENOENT),
                    userInfo: [NSFilePathErrorKey: rebuildJournal.path])
            })
        XCTAssertEqual(attempts, 3, "Rebuild journal retries remain bounded")
        for rejected in [
            index.appendingPathComponent("personal-rebuild-not-a-uuid.sqlite-journal"),
            index.appendingPathComponent("items.sqlite-journal"),
            root.appendingPathComponent("store/other/" + rebuildJournal.lastPathComponent),
            root.appendingPathComponent("store/.tractanda/revision.json"),
        ] {
            attempts = 0
            XCTAssertThrowsError(
                try capacity(root) { _ in
                    attempts += 1
                    throw NSError(
                        domain: NSPOSIXErrorDomain, code: Int(ENOENT),
                        userInfo: [NSFilePathErrorKey: rejected.path])
                })
            XCTAssertEqual(attempts, 1, "Unknown and canonical paths must not be retried")
        }
    }

    func testReaderRequirementStageDisappearanceRetriesWholeBoundedInventory() throws {
        let root = try GuardedFixtureDirectory.create(
            prefix: "j", source: "DocumentJobCoordinatorTests", test: name)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("store")
        try FileManager.default.createDirectory(
            at: store, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let id = "ABCDEF12-1234-4ABC-8ABC-ABCDEF123456"
        let stage = store.appendingPathComponent(".reader-requirement-" + id + ".stage")
        let probe = root.appendingPathComponent("probe")
        try Data([1]).write(to: probe)
        try Data([1]).write(to: stage)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stage.path)
        var removed = false
        try capacity(root) { url in
            if url.path == stage.path, !removed {
                try FileManager.default.removeItem(at: url)
                removed = true
            }
        }
        XCTAssertTrue(removed, "The enumerated reader stage must actually disappear")

        try Data([1]).write(to: stage)
        let oversized = root.appendingPathComponent("oversized-after-reader-stage")
        var introducedOversized = false
        XCTAssertThrowsError(
            try capacity(root) { url in
                if url.path == stage.path, !introducedOversized {
                    try FileManager.default.removeItem(at: url)
                    let fd = open(oversized.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
                    guard fd >= 0 else { throw POSIXError(.EIO) }
                    defer { _ = close(fd) }
                    guard ftruncate(fd, 16 * 1024 * 1024 + 1) == 0 else { throw POSIXError(.EIO) }
                    introducedOversized = true
                }
            }
        ) { error in
            XCTAssertEqual((error as? TractandaError)?.code, "resourceLimit")
        }
        XCTAssertTrue(introducedOversized, "The retry must rescan and enforce the complete cap")
        try FileManager.default.removeItem(at: oversized)

        var attempts = 0
        XCTAssertThrowsError(
            try capacity(root) { _ in
                attempts += 1
                throw NSError(
                    domain: NSPOSIXErrorDomain, code: Int(ENOENT), userInfo: [NSFilePathErrorKey: stage.path])
            })
        XCTAssertEqual(attempts, 3, "Reader-stage retries remain bounded")
        for rejected in [
            store.appendingPathComponent("canonical-reader.json"),
            store.appendingPathComponent(".reader-requirement-" + id.lowercased() + ".stage"),
            store.appendingPathComponent(".reader-requirement-not-a-uuid.stage"),
            root.appendingPathComponent("other/" + stage.lastPathComponent),
        ] {
            attempts = 0
            XCTAssertThrowsError(
                try capacity(root) { _ in
                    attempts += 1
                    throw NSError(
                        domain: NSPOSIXErrorDomain, code: Int(ENOENT),
                        userInfo: [NSFilePathErrorKey: rejected.path])
                })
            XCTAssertEqual(attempts, 1, "Durable, malformed and wrong-root paths must not be retried")
        }
        attempts = 0
        XCTAssertThrowsError(
            try capacity(root) { _ in
                attempts += 1
                throw NSError(
                    domain: NSPOSIXErrorDomain, code: Int(EACCES), userInfo: [NSFilePathErrorKey: stage.path])
            })
        XCTAssertEqual(attempts, 1, "Non-ENOENT errors must not be retried")
        try FileManager.default.createSymbolicLink(at: stage, withDestinationURL: probe)
        XCTAssertThrowsError(try accountedBytes(stage, root: root))
        XCTAssertThrowsError(try capacity(root), "An exact-name stage symlink must not be accepted")
    }

    func testFixturePhysicalPathsRejectAliasesAndEscapedRelativeEntries() throws {
        let root = try GuardedFixtureDirectory.create(
            prefix: "j", source: "DocumentJobCoordinatorTests", test: name)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try GuardedFixtureDirectory.physical(root).path, root.path)
        _ = try GuardedFixtureDirectory.validate(root)
        let child = root.appendingPathComponent("child")
        try FileManager.default.createDirectory(
            at: child, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = child.appendingPathComponent("value")
        try Data([1]).write(to: file)
        XCTAssertEqual(try GuardedFixtureDirectory.relativePath(file, beneath: root), "child/value")
        XCTAssertThrowsError(try GuardedFixtureDirectory.relativePath(root, beneath: child))
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: child)
        XCTAssertThrowsError(try GuardedFixtureDirectory.validate(alias))
        XCTAssertThrowsError(
            try GuardedFixtureDirectory.relativePath(alias.appendingPathComponent("value"), beneath: root))
        let leaf = child.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: file)
        XCTAssertEqual(try GuardedFixtureDirectory.relativePath(leaf, beneath: root), "child/link")
        var metadata = stat()
        XCTAssertEqual(lstat(leaf.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & mode_t(S_IFMT), mode_t(S_IFLNK))
    }

    func testFixtureCapacityFollowsOnlyOwnedSealedPromotionCounterpart() throws {
        let root = try GuardedFixtureDirectory.create(
            prefix: "j", source: "DocumentJobCoordinatorTests", test: name)
        defer { try? FileManager.default.removeItem(at: root) }
        try capacity(root)
        let store = root.appendingPathComponent("store")
        try FileManager.default.createDirectory(
            at: store, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let content = DocumentContentStore(
            root: store, ownerUID: getuid(),
            minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes)
        let sourceID = try UUID.makeVersion1().uuidString.lowercased()
        let source = try AttachmentDocumentSource(
            itemID: sourceID, revisionID: sourceID,
            attachmentID: sourceID, sha256: String(repeating: "a", count: 64),
            byteCount: 3, mediaType: "application/pdf")
        // Begin initializes canonical StoreID/placement before creating staging content.
        let writer = try content.begin(source: source, identity: .init())
        try writer.append(
            DocumentStoredPage(
                pageNumber: 1, sourceSHA256: source.sha256,
                status: "failed", failureCode: "syntheticFixture"))
        let prepared = try writer.preparePublication()
        let stage = prepared.stage.reduce(store) { $0.appendingPathComponent($1) }
        let page = stage.appendingPathComponent("pages/0/1.json")
        let pageBytes = try Data(contentsOf: page)
        var reference: DocumentContentReference?
        try capacity(root) { url in
            if url.path == page.path { reference = try content.publishPrepared(prepared) }
        }
        let publishedReference = try XCTUnwrap(reference)
        XCTAssertNotEqual(
            prepared.stage.last, publishedReference.contentID,
            "Publication assigns a new content identity; staging UUID is not its placement key")
        let canonical = try content.directory(publishedReference.contentID).reduce(store) {
            $0.appendingPathComponent($1)
        }
        XCTAssertEqual(try accountedBytes(page, root: root), UInt64(pageBytes.count))
        let published = canonical.appendingPathComponent("pages/0/1.json")
        try FileManager.default.removeItem(at: published)
        XCTAssertThrowsError(
            try accountedBytes(page, root: root), "A missing canonical counterpart is not a promotion")
        let elsewhere = root.appendingPathComponent("elsewhere")
        try Data([1]).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: published, withDestinationURL: elsewhere)
        XCTAssertThrowsError(
            try accountedBytes(page, root: root), "Never follow a canonical counterpart symlink")
    }

    func testFixtureCapacityWaitsForConfirmedInFlightPublication() async throws {
        let root = try GuardedFixtureDirectory.create(
            prefix: "j", source: "DocumentJobCoordinatorTests", test: name)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("store")
        try FileManager.default.createDirectory(
            at: store, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let content = DocumentContentStore(
            root: store, ownerUID: getuid(), minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes)
        let id = try UUID.makeVersion1().uuidString.lowercased()
        let source = try AttachmentDocumentSource(
            itemID: id, revisionID: id, attachmentID: id, sha256: String(repeating: "a", count: 64),
            byteCount: 3, mediaType: "application/pdf")
        let writer = try content.begin(source: source, identity: .init())
        try writer.append(
            DocumentStoredPage(
                pageNumber: 1, sourceSHA256: source.sha256,
                status: "failed", failureCode: "syntheticFixture"))
        let prepared = try writer.preparePublication()
        let page = prepared.stage.reduce(store) { $0.appendingPathComponent($1) }
            .appendingPathComponent("pages/0/1.json")
        let pageBytes = try Data(contentsOf: page).count
        let renamed = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        content.afterDirectoryRenameForTesting = {
            renamed.signal()
            guard release.wait(timeout: .now() + 30) == .success else {
                throw TractandaError(
                    "testTimeout", "Fixture inventory did not observe publication contention.")
            }
        }
        var contentionCount = 0
        publicationContentionForTesting = {
            contentionCount += 1
            release.signal()
        }
        defer { publicationContentionForTesting = nil }
        var publisher: Task<DocumentContentReference, Error>?
        do {
            try capacity(root) { url in
                if url.path == page.path {
                    publisher = Task.detached { try content.publishPrepared(prepared) }
                    guard renamed.wait(timeout: .now() + 30) == .success else {
                        throw TractandaError("testTimeout", "Fixture publication did not reach its rename.")
                    }
                }
            }
        } catch {
            release.signal()
            _ = await publisher?.result
            throw error
        }
        let publication = try XCTUnwrap(publisher)
        let reference = try await publication.value
        XCTAssertGreaterThan(contentionCount, 0, "The exact post-rename placement lock must be observed")
        XCTAssertEqual(try accountedBytes(page, root: root), UInt64(pageBytes))
        let canonical = try content.pageURLForTesting(reference, number: 1)
        try FileManager.default.removeItem(at: canonical)
        XCTAssertThrowsError(try accountedBytes(page, root: root))
    }

    // Staging promotion changes paths, not data. Require the exact dated canonical counterpart
    // through the existing directory recipe; every component is inspected without following links.
    private func promotedEntry(_ url: URL, root: URL) throws -> (URL, stat)? {
        let staging = root.appendingPathComponent("store/documents/.staging").path + "/"
        guard url.path.hasPrefix(staging) else { return nil }
        let parts = url.path.dropFirst(staging.count).split(separator: "/").map(String.init)
        guard let id = parts.first, UUID(uuidString: id)?.version1Components != nil,
            parts.allSatisfy({ $0 != "." && $0 != ".." })
        else { return nil }
        let store = root.appendingPathComponent("store")
        let files = DocumentContentFiles(
            root: store, ownerUID: getuid(),
            minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes)
        guard
            let bytes = try? files.read(
                path: ["documents", ".staging", id + ".publication.json"],
                maximumBytes: DocumentContentStore.maximumNodeBytes),
            let receipt = try? DocumentValue.strictDecode(DocumentPublicationReceipt.self, data: bytes),
            receipt.manifest.publicationID == id, DocumentHashNode.isDigest(receipt.preparedSHA256),
            let manifestBytes = try? JSON.encode(receipt.manifest),
            let reference = try? DocumentContentReference(
                contentID: receipt.manifest.contentID,
                manifestSHA256: PageCorpusInput.digest(manifestBytes),
                rootSHA256: receipt.manifest.rootSHA256,
                pageCount: receipt.manifest.pageCount, totalEncodedBytes: receipt.manifest.totalEncodedBytes,
                coverage: receipt.manifest.coverage)
        else { return nil }
        let content = DocumentContentStore(root: store, ownerUID: getuid())
        guard let publication = try publicationDirectory(content, reference: reference),
            publication.0 == receipt.manifest
        else { return nil }
        let components = publication.1 + Array(parts.dropFirst())
        var path = store
        var metadata = stat()
        for (index, component) in components.enumerated() {
            path.appendPathComponent(component)
            guard lstat(path.path, &metadata) == 0, metadata.st_uid == getuid(), metadata.st_mode & 0o022 == 0
            else { return nil }
            if index < components.count - 1 {
                guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { return nil }
            }
        }
        let directory = metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        let sealed =
            metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && metadata.st_mode & 0o777 == 0o400 && metadata.st_size > 0
            && metadata.st_size <= DocumentContentStore.maximumPageBytes
        return directory || sealed ? (path, metadata) : nil
    }

    private func publicationDirectory(
        _ content: DocumentContentStore, reference: DocumentContentReference
    ) throws -> (DocumentManifest, [String])? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while true {
            do {
                return (try content.manifest(reference), try content.directory(reference.contentID))
            } catch {
                // tractanda_lock resets its thread-local cause on every attempt. Inspect it
                // immediately after this exact placement-lock failure, before any other lookup.
                let busy = tractanda_lock_was_busy() != 0
                guard let failure = error as? TractandaError, failure.code == "documentIntegrity",
                    failure.message == "Document placement is busy or unsafe.", busy
                else { return nil }
                publicationContentionForTesting?()
                guard clock.now < deadline else {
                    throw TractandaError("testTimeout", "Fixture publication placement remained busy.")
                }
                Thread.sleep(forTimeInterval: 0.001)
            }
        }
    }

    private var temporaryDirectory: URL {
        get throws { try GuardedFixtureDirectory.parent() }
    }

    private func accountedBytes(_ url: URL, root: URL) throws -> UInt64 {
        var metadata = stat()
        if lstat(url.path, &metadata) == 0 {
            if readerRequirementStage(url, root: root) {
                guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                    metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0, metadata.st_nlink == 1
                else {
                    throw TractandaError("resourceLimit", "Unsafe reader-requirement stage in fixture.")
                }
            }
            guard metadata.st_size >= 0 else {
                throw TractandaError("resourceLimit", "Fixture file size is unknown.")
            }
            return metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) ? UInt64(metadata.st_size) : 0
        }
        let failure = errno
        if failure == ENOENT, let promoted = try promotedEntry(url, root: root),
            promoted.1.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        {
            return UInt64(promoted.1.st_size)
        }
        let staging = root.appendingPathComponent("store/documents/.staging").path + "/"
        let name = url.lastPathComponent
        let rebuildPrefix = ".rebuild-status-"
        if failure == ENOENT,
            url.deletingLastPathComponent().path == root.appendingPathComponent("store").path,
            name.hasPrefix(rebuildPrefix), String(name.dropFirst(rebuildPrefix.count)).count == 36,
            UUID(uuidString: String(name.dropFirst(rebuildPrefix.count))) != nil
        {
            // RebuildJournal.save stages only <=16KiB before atomic rename/unlink.
            // The durable .rebuild-status.json and all canonical paths still fail closed.
            return 16 * 1024
        }
        if failure == ENOENT, url.path.hasPrefix(staging), name.hasPrefix(".dependency-"),
            name.hasSuffix(".tmp"), UUID(uuidString: String(name.dropFirst(12).dropLast(4))) != nil
        {
            let parts = url.path.dropFirst(staging.count).split(separator: "/")
            let tree = parts.count >= 2 && UUID(uuidString: String(parts[0]))?.version1Components != nil
            guard parts.count == 1 || tree
            else {
                throw NSError(
                    domain: NSPOSIXErrorDomain, code: Int(failure), userInfo: [NSFilePathErrorKey: url.path])
            }
            // DocumentContentFiles.write publishes/unlinks these staging-only files atomically.
            return UInt64(DocumentContentStore.maximumPageBytes)
        }
        if failure == ENOENT, url.deletingLastPathComponent().path + "/" == staging,
            name.hasSuffix(".publication.json"),
            UUID(uuidString: String(name.dropLast(17)))?.version1Components != nil
        {
            return UInt64(DocumentContentStore.maximumPageBytes)
        }
        if failure == ENOENT, name.hasPrefix(".dependency-"), name.hasSuffix(".tmp"),
            UUID(uuidString: String(name.dropFirst(12).dropLast(4))) != nil
        {
            for (namespace, bound) in [("document-job-history", 16 * 1024), ("document-job-operations", 128)]
            {
                let parent = url.deletingLastPathComponent()
                if parent.deletingLastPathComponent().path
                    == root.appendingPathComponent("store/" + namespace).path,
                    parent.lastPathComponent.count == 2
                {
                    return UInt64(bound)
                }
            }
        }
        let jobs = root.appendingPathComponent("store/document-jobs")
        guard failure == ENOENT, url.path.hasPrefix(jobs.path + "/") else {
            throw NSError(
                domain: NSPOSIXErrorDomain, code: Int(failure), userInfo: [NSFilePathErrorKey: url.path])
        }
        // Atomic operational checkpoints can be renamed between enumeration and lstat.
        // Charge their full runtime maximum instead of treating a vanished file as zero.
        if name.hasPrefix(".checkpoint-"), name.hasSuffix(".tmp"),
            UUID(uuidString: String(name.dropFirst(12).dropLast(4))) != nil,
            url.deletingLastPathComponent().deletingLastPathComponent().path == jobs.path
        {
            return 16 * 1024
        }
        if name == "projection.sqlite-journal",
            url.deletingLastPathComponent().lastPathComponent.hasPrefix("page-corpus-"),
            url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "corpus",
            url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().path == jobs.path
        {
            let database = url.deletingLastPathComponent().appendingPathComponent("projection.sqlite")
            var size = stat()
            guard lstat(database.path, &size) == 0,
                size.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), size.st_size >= 0,
                size.st_size <= 8 * 1024 * 1024
            else { throw TractandaError("resourceLimit", "Cannot bound a vanished fixture journal.") }
            // Conservative rollback-journal allowance includes page-record/header overhead.
            return UInt64(size.st_size) * 2 + 4096
        }
        // Missing canonical records/pages, other metadata errors and unknown paths still fail closed.
        throw NSError(
            domain: NSPOSIXErrorDomain, code: Int(failure), userInfo: [NSFilePathErrorKey: url.path])
    }

    func testFixtureCapacityAccountsOnlyVanishedOperationalFiles() throws {
        let root = try GuardedFixtureDirectory.create(
            prefix: "j", source: "DocumentJobCoordinatorTests", test: name)
        defer { try? FileManager.default.removeItem(at: root) }
        try capacity(root)
        let job = root.appendingPathComponent("store/document-jobs/" + Identifier.make())
        let corpus = job.appendingPathComponent("corpus/page-corpus-" + Identifier.make())
        try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
        let checkpoint = job.appendingPathComponent(".checkpoint-" + UUID().uuidString + ".tmp")
        let journal = corpus.appendingPathComponent("projection.sqlite-journal")
        let rebuildTemporary = root.appendingPathComponent("store/.rebuild-status-" + UUID().uuidString)
        let representation = try UUID.makeVersion1().uuidString.lowercased()
        let pages = root.appendingPathComponent("store/documents/.staging/" + representation + "/pages/0")
        try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true)
        let dependency = pages.appendingPathComponent(".dependency-" + UUID().uuidString + ".tmp")
        try Data([1]).write(to: checkpoint)
        try Data([1]).write(to: journal)
        try Data([1]).write(to: rebuildTemporary)
        try Data([1]).write(to: dependency)
        try Data([1]).write(to: corpus.appendingPathComponent("projection.sqlite"))
        var removed: Set<String> = []
        try capacity(root) { url in
            if [checkpoint.path, journal.path, rebuildTemporary.path, dependency.path].contains(url.path) {
                try FileManager.default.removeItem(at: url)
                removed.insert(url.path)
            }
        }
        XCTAssertEqual(removed, Set([checkpoint.path, journal.path, rebuildTemporary.path, dependency.path]))
        XCTAssertEqual(try accountedBytes(checkpoint, root: root), 16 * 1024)
        XCTAssertEqual(try accountedBytes(rebuildTemporary, root: root), 16 * 1024)
        for rejected in [".rebuild-status.json", ".rebuild-status-not-a-uuid", "canonical.json"] {
            XCTAssertThrowsError(
                try accountedBytes(root.appendingPathComponent("store/" + rejected), root: root))
        }
        XCTAssertEqual(try accountedBytes(journal, root: root), 4098)
        XCTAssertEqual(
            try accountedBytes(dependency, root: root), UInt64(DocumentContentStore.maximumPageBytes))
        XCTAssertThrowsError(
            try accountedBytes(
                root.appendingPathComponent(
                    "store/documents/" + representation + "/pages/0/" + dependency.lastPathComponent),
                root: root))
        XCTAssertThrowsError(try accountedBytes(job.appendingPathComponent("record.json"), root: root))
        XCTAssertThrowsError(try accountedBytes(corpus.appendingPathComponent("page.json"), root: root))
        XCTAssertThrowsError(
            try accountedBytes(corpus.appendingPathComponent(checkpoint.lastPathComponent), root: root))
        try FileManager.default.removeItem(at: corpus.appendingPathComponent("projection.sqlite"))
        XCTAssertThrowsError(try accountedBytes(journal, root: root))
    }
    private func fixture(
        delay: Double = 0, pages: Int = 129, heldPage: Int? = nil, accounts: Accounts? = nil
    ) throws -> Fixture {
        try capacity(temporaryDirectory)
        let root = try GuardedFixtureDirectory.create(
            prefix: "j", source: "DocumentJobCoordinatorTests", test: name)
        let storeURL = root.appendingPathComponent("store")
        let request: DocumentJobStart = try {
            let selectedAccounts: any AccountDirectory
            if let accounts {
                selectedAccounts = accounts
            } else {
                selectedAccounts = SystemAccountDirectory()
            }
            let initialAccess =
                accounts == nil
                ? nil
                : ItemValue.object([
                    "profile": .text(AccessConfiguration.profile), "groups": .list([.text("staff")]),
                ])
            _ = try ItemStore.initializeFresh(
                root: storeURL, accounts: selectedAccounts, initialAccessConfiguration: initialAccess)
            let store = try ItemStore.openInitialized(root: storeURL, accounts: selectedAccounts)
            try store.setAttachmentReserveForTesting(10 * 1024 * 1024 * 1024)
            let item = try store.commit(CommitRequest(classID: "Item", operationID: "item")).revision
            let bytes = Data([1, 2, 3])
            let upload = try store.beginAttachment(
                AttachmentUploadRequest(
                    itemID: item.itemID,
                    expectedRevisionID: item.revisionID, operationID: "original", filename: "tiny.pdf",
                    mediaType: "application/pdf", byteCount: 3, sha256: PageCorpusInput.digest(bytes)))
            let id = try XCTUnwrap(upload.uploadID)
            _ = try store.appendAttachment(uploadID: id, offset: 0, data: bytes)
            let attached = try store.finishAttachment(uploadID: id).revision
            return DocumentJobStart(
                itemID: attached.itemID, expectedRevisionID: attached.revisionID,
                attachmentID: upload.attachment.attachmentID, operationID: "document-job")
        }()
        let executable = root.appendingPathComponent("worker.py")
        let script = """
            #!/usr/bin/python3
            import sys,json,time,pathlib
            binding=json.load(open(sys.argv[5]))
            def emit(value):
                result=dict(binding);result.update(value)
                print(json.dumps(result,separators=(',',':')),flush=True)
            emit({'type':'hello','pageCount':\(pages),'modelLoaded':False,'modelForwardCalls':0})
            open(\(String(reflecting: root.appendingPathComponent("worker-pid").path)), 'w').write(str(__import__('os').getpid()))
            loaded=False
            for line in sys.stdin:
                request=json.loads(line)
                if request['method']=='close':
                    emit({'type':'closed','requestID':request['requestID']});break
                with open(\(String(reflecting: root.appendingPathComponent("page-calls").path)), 'a') as calls:
                    calls.write(str(request['pageNumber'])+'\\n')
                base={'requestID':request['requestID'],'pageNumber':request['pageNumber']}
                if not loaded:
                    emit(dict(base,type='progress',phase='modelReady',completed=0,total=0));loaded=True
                emit(dict(base,type='progress',phase='render',completed=0,total=0))
                if request['pageNumber']==\(heldPage ?? -1):
                    pathlib.Path(\(String(reflecting: root.appendingPathComponent("held-page").path))).write_text(str(request['pageNumber']))
                    deadline=time.monotonic()+8
                    while not pathlib.Path(\(String(reflecting: root.appendingPathComponent("release-page").path))).exists():
                        if time.monotonic()>deadline: raise RuntimeError('bounded held-page deadline')
                        time.sleep(0.01)
                time.sleep(\(delay))
                emit(dict(base,type='page',status='unsupported',failureCode='unsupportedDocumentInput'))
            """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let model = root.appendingPathComponent("empty-model")
        try FileManager.default.createDirectory(
            at: model, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let configuration = DocumentConverterConfiguration(
            executablePath: executable.path,
            modelDirectory: model.path, scratchDirectory: root.appendingPathComponent("scratch").path)
        try capacity(root)
        return Fixture(root: root, store: storeURL, configuration: configuration, request: request)
    }
    private func client(_ coordinator: ServiceCoordinator, uid: UInt32 = UInt32(getuid()))
        -> TractandaClient.ItemClient
    {
        TractandaClient.ItemClient(transport: Transport(coordinator: coordinator, uid: uid))
    }
    private func wait(
        _ client: TractandaClient.ItemClient, id: String, root: URL,
        until predicate: (DocumentJobStatus) -> Bool
    ) async throws -> DocumentJobStatus {
        var last: DocumentJobStatus?
        for _ in 0..<600 {
            try capacity(root)
            let status = try await client.documentJob(id)
            last = status
            if predicate(status) { return status }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TractandaError(
            "testTimeout",
            "Bounded fake-worker completion was not observed: \(last?.state ?? "unknown")/\(last?.reasonCode ?? "none") pages=\(last?.acceptedPages ?? -1)."
        )
    }
    #if os(Linux)
        func testPublicCoordinatorRetainsRealRuntimePreflight() async throws {
            guard try DocumentLinuxRuntimeClosure.compiledCurrentDigest() != nil else {
                throw XCTSkip("Requires the finite production Linux profile")
            }
            let fixture = try fixture(pages: 1)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            // Intentionally the unchanged public constructor, without any fixture seam.
            let coordinator = try await ServiceCoordinator(
                opening: fixture.store, documentConverter: fixture.configuration)
            let client = client(coordinator)
            let admitted = try await client.startDocumentJob(fixture.request)
            let paused = try await wait(client, id: admitted.jobID, root: fixture.root) {
                $0.state == "paused"
            }
            XCTAssertEqual(paused.reasonCode, "documentConverter")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("worker-pid").path)
            )
            await coordinator.close()
        }
    #endif

    func testCoordinatorVerifierFailurePreventsWorkerLaunch() async throws {
        let fixture = try fixture(pages: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = try await ServiceCoordinator(
            opening: fixture.store, embeddingProviderForTesting: nil, requireInitializedStore: true,
            documentRuntimeVerifierForTesting: { _ in
                throw TractandaError("fixtureVerifierRejected", "Internal verifier called")
            }, documentConverter: fixture.configuration)
        let client = client(coordinator)
        let admitted = try await client.startDocumentJob(fixture.request)
        let paused = try await wait(client, id: admitted.jobID, root: fixture.root) { $0.state == "paused" }
        XCTAssertEqual(paused.reasonCode, "fixtureVerifierRejected")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("worker-pid").path))
        await coordinator.close()
    }

    func testPartialIndexImportRestartReusesSavedPagesWithoutConverterReplay() async throws {
        // Three outcomes + all store/index/spool copies are estimated below2MiB under16MiB.
        let fixture = try fixture(pages: 3)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try await ServiceCoordinator(
            opening: fixture.store, embeddingProviderForTesting: nil, requireInitializedStore: true,
            documentRuntimeVerifierForTesting: { _ in }, documentConverter: fixture.configuration)
        await first.setDocumentJobIndexHookForTesting { batch in
            if batch.phase == .afterCommit {
                throw TractandaError("indexProjectionPending", "Stopped after durable partial import")
            }
        }
        let admitted = try await client(first).startDocumentJob(fixture.request)
        let paused = try await wait(client(first), id: admitted.jobID, root: fixture.root) {
            $0.state == "paused"
        }
        XCTAssertEqual(paused.acceptedPages, 3)
        await first.close()
        let calls = try String(contentsOf: fixture.root.appendingPathComponent("page-calls"), encoding: .utf8)
        let second = try await ServiceCoordinator(
            opening: fixture.store, embeddingProviderForTesting: nil, requireInitializedStore: true,
            documentRuntimeVerifierForTesting: { _ in }, documentConverter: fixture.configuration)
        let completed = try await wait(client(second), id: admitted.jobID, root: fixture.root) {
            $0.state == "completed"
        }
        XCTAssertTrue(completed.committed?.isIndexReady == true)
        XCTAssertEqual(
            try String(contentsOf: fixture.root.appendingPathComponent("page-calls"), encoding: .utf8), calls)
        await second.close()
        try capacity(fixture.root)
    }
    func testPartialIndexRebaseRefreshesFieldsAndDiscardCleansDurableDebt() async throws {
        let fixture = try fixture(pages: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try await ServiceCoordinator(
            opening: fixture.store, embeddingProviderForTesting: nil, requireInitializedStore: true,
            documentRuntimeVerifierForTesting: { _ in }, documentConverter: fixture.configuration)
        let admitted: DocumentJobStatus
        do {
            await first.setDocumentJobIndexHookForTesting { batch in
                if batch.phase == .afterCommit {
                    throw TractandaError("testPaused", "Retained partial index")
                }
            }
            admitted = try await client(first).startDocumentJob(fixture.request)
            _ = try await wait(client(first), id: admitted.jobID, root: fixture.root) { $0.state == "paused" }
        } catch {
            await first.close()
            throw error
        }
        await first.close()
        let calls = try String(contentsOf: fixture.root.appendingPathComponent("page-calls"), encoding: .utf8)
        let changedID: String
        do {
            let store = try ItemStore.openInitialized(root: fixture.store)
            let changed = try store.commit(
                CommitRequest(
                    action: .revise, itemID: fixture.request.itemID,
                    expectedRevisionID: fixture.request.expectedRevisionID,
                    changes: ["subject": .text("fresh rebase field")], operationID: "rebase-field")
            ).revision
            changedID = changed.revisionID
            let runtime = try XCTUnwrap(
                ItemService(store: store, documentConverter: fixture.configuration).documentJobRuntime())
            _ = try store.controlDocumentJob(
                admitted.jobID, action: "rebase", expectedRevisionID: changedID,
                configurationSHA256: runtime.configurationSHA256, deferMaterialWork: true)
        }
        let second = try await ServiceCoordinator(
            opening: fixture.store, embeddingProviderForTesting: nil, requireInitializedStore: true,
            documentRuntimeVerifierForTesting: { _ in }, documentConverter: fixture.configuration)
        do {
            let done = try await wait(client(second), id: admitted.jobID, root: fixture.root) {
                $0.state == "completed"
            }
            XCTAssertEqual(done.sourceRevisionID, fixture.request.expectedRevisionID)
            XCTAssertEqual(done.expectedRevisionID, changedID)
        } catch {
            await second.close()
            throw error
        }
        await second.close()
        XCTAssertEqual(
            try String(contentsOf: fixture.root.appendingPathComponent("page-calls"), encoding: .utf8), calls)
        do {
            let store = try ItemStore.openInitialized(root: fixture.store)
            let saved = try store.get(fixture.request.itemID)
            XCTAssertEqual(saved.fields["subject"], .text("fresh rebase field"))
            XCTAssertEqual(
                try AttachmentDocumentRepresentation.representations(in: saved.fields).first?.source
                    .revisionID,
                fixture.request.expectedRevisionID)
        }
        try capacity(fixture.root)
    }
    func testPartialIndexDiscardRetiresBeforeArchivedPhysicalDisposal() async throws {
        let fixture = try fixture(pages: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try await ServiceCoordinator(
            opening: fixture.store, embeddingProviderForTesting: nil, requireInitializedStore: true,
            documentRuntimeVerifierForTesting: { _ in }, documentConverter: fixture.configuration)
        await first.setDocumentJobIndexHookForTesting { batch in
            if batch.phase == .afterCommit { throw TractandaError("testPaused", "Retained partial index") }
        }
        let admitted = try await client(first).startDocumentJob(fixture.request)
        _ = try await wait(client(first), id: admitted.jobID, root: fixture.root) { $0.state == "paused" }
        _ = try await client(first).discardDocumentJob(admitted.jobID)
        await first.close()
        let second = try await ServiceCoordinator(
            opening: fixture.store, embeddingProviderForTesting: nil, requireInitializedStore: true,
            documentRuntimeVerifierForTesting: { _ in }, documentConverter: fixture.configuration)
        await second.close()
        let store = try ItemStore.openInitialized(root: fixture.store)
        XCTAssertTrue(try store.documentJobStatus(admitted.jobID).discarded)
        let index = try ItemIndex(
            path: store.indexDirectory.appendingPathComponent("items.sqlite").path, create: false)
        XCTAssertEqual(try index.corpusRetainedBytes(admitted.jobID), 0)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.store.appendingPathComponent("document-jobs/" + admitted.jobID).path))
        try capacity(fixture.root)
    }
    func testActualRouter129PagesCompleteOnlyAfterIndexPromotion() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = try await ServiceCoordinator(
            opening: fixture.store, embeddingProviderForTesting: nil, requireInitializedStore: true,
            documentRuntimeVerifierForTesting: { _ in }, documentConverter: fixture.configuration)
        let gate = AdmissionGate()
        await coordinator.setDocumentJobPublicationHookForTesting { await gate.pause() }
        let client = client(coordinator)
        let admitted = try await client.startDocumentJob(fixture.request)
        try await waitForGate(gate, maximumAttempts: 1200)
        let status = try await client.documentJob(admitted.jobID)
        XCTAssertEqual(status.acceptedPages, 129)
        XCTAssertEqual(status.coverage.unsupported, 129)
        XCTAssertNil(status.committed)
        let page = try await client.documentJobPage(status.jobID, pageNumber: 129)
        XCTAssertTrue(page.provisional)
        XCTAssertEqual(page.outcome.pageNumber, 129)
        await coordinator.setDocumentJobPublicationHookForTesting(nil)
        await gate.release()
        let completed = try await wait(client, id: admitted.jobID, root: fixture.root) {
            $0.state == "completed"
        }
        XCTAssertTrue(completed.committed?.isIndexReady == true)
        let canonical = try await client.attachmentDocument(
            itemID: fixture.request.itemID,
            attachmentID: fixture.request.attachmentID, pageNumber: 129)
        XCTAssertEqual(canonical.outcomes?.first?.pageNumber, 129)
        let replay = try await client.startDocumentJob(fixture.request)
        XCTAssertEqual(replay.jobID, admitted.jobID)
        await coordinator.close()
        try capacity(fixture.root)
    }
    func testQueuedJobKeepsReadsAndExactAdmissionReplayAvailable() async throws {
        let fixture: Fixture
        do { fixture = try self.fixture(pages: 3) } catch {
            let failure = error as NSError
            print("DJC queued fixture failed domain=\(failure.domain) code=\(failure.code)")
            throw error
        }
        var phase = "coordinator"
        var closed = false
        defer {
            print("DJC queued remove-root phase=\(phase) closed=\(closed) root=\(fixture.root.path)")
            do {
                try FileManager.default.removeItem(at: fixture.root)
                print("DJC queued remove-root returned")
            } catch {
                let failure = error as NSError
                print("DJC queued cleanup failed domain=\(failure.domain) code=\(failure.code)")
                print(Thread.callStackSymbols.joined(separator: "\n"))
            }
        }
        let coordinator = try await ServiceCoordinator(
            opening: fixture.store, embeddingProviderForTesting: nil, requireInitializedStore: true,
            documentRuntimeVerifierForTesting: { _ in }, documentConverter: fixture.configuration)
        let gate = AdmissionGate()
        await coordinator.setDocumentJobAdmissionHookForTesting { await gate.pause() }
        do {
            phase = "admission-and-replay"
            let client = client(coordinator)
            let admitted = try await client.startDocumentJob(fixture.request)
            try await waitForGate(gate)
            let info = try nativeFixtureEnvelope(
                calls: [["TractandaStore/info", [:], "read"]],
                accountID: nativeFixtureAccountID(fixture.store))
            let response = try await coordinator.handle(info, forUID: getuid())
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
            XCTAssertNil(root["code"])
            XCTAssertNotNil(root["methodResponses"])
            let replay = try await client.startDocumentJob(fixture.request)
            XCTAssertEqual(replay.jobID, admitted.jobID)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("worker-pid").path)
            )
            await coordinator.setDocumentJobAdmissionHookForTesting(nil)
            await gate.release()
            phase = "wait-completed"
            let completed = try await wait(client, id: admitted.jobID, root: fixture.root) {
                $0.state == "completed"
            }
            XCTAssertEqual(completed.acceptedPages, 3)
            print("DJC queued wait-completed returned")
            let calls = try String(
                contentsOf: fixture.root.appendingPathComponent("page-calls"), encoding: .utf8)
            XCTAssertEqual(calls.split(separator: "\n"), ["1", "2", "3"])
            phase = "close"
            await coordinator.close()
            closed = true
            print("DJC queued coordinator.close returned")
        } catch {
            let original = error
            let failure = original as NSError
            print("DJC queued body failed phase=\(phase) domain=\(failure.domain) code=\(failure.code)")
            await coordinator.setDocumentJobAdmissionHookForTesting(nil)
            await gate.release()
            await coordinator.close()
            closed = true
            print("DJC queued error-path coordinator.close returned")
            throw original
        }
    }

    func testRetainedJobsAccessibleWithoutConfiguredConverter() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id: String = try {
            let store = try ItemStore.openInitialized(root: fixture.store)
            let runtime = try XCTUnwrap(
                ItemService(store: store, documentConverter: fixture.configuration).documentJobRuntime())
            return try store.startDocumentJob(
                fixture.request, identity: .init(), configurationSHA256: runtime.configurationSHA256
            ).jobID
        }()
        let coordinator = try await ServiceCoordinator(opening: fixture.store)
        let client = client(coordinator)
        let retained = try await client.documentJob(id)
        let listed = try await client.documentJobs()
        XCTAssertEqual(retained.jobID, id)
        XCTAssertEqual(listed.jobs.count, 1)
        let recordURL = fixture.store.appendingPathComponent("document-jobs/\(id)/record.json")
        let beforeRecord = try Data(contentsOf: recordURL)
        let beforeMetadata = try FileMetadata.read(at: recordURL)
        do {
            _ = try await client.resumeDocumentJob(id)
            XCTFail("Unconfigured producer must not resume")
        } catch { XCTAssertEqual((error as? TractandaError)?.code, "documentConverterUnavailable") }
        XCTAssertEqual(try Data(contentsOf: recordURL), beforeRecord)
        XCTAssertEqual(try FileMetadata.read(at: recordURL), beforeMetadata)
        let cancelled = try await client.cancelDocumentJob(id)
        let discarded = try await client.discardDocumentJob(id)
        XCTAssertEqual(cancelled.state, "cancelled")
        XCTAssertTrue(discarded.discarded)
        for _ in 0..<100 {
            if try await client.documentJobs().jobs.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let afterDisposal = try await client.documentJobs()
        XCTAssertTrue(afterDisposal.jobs.isEmpty)
        await coordinator.close()
    }
    func testCloseDrainsProducerAndStartupResumesAcknowledgedFrontier() async throws {
        let fixture = try fixture(delay: 0.002)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try await ServiceCoordinator(
            opening: fixture.store, embeddingProviderForTesting: nil, requireInitializedStore: true,
            documentRuntimeVerifierForTesting: { _ in }, documentConverter: fixture.configuration)
        let admitted: DocumentJobStatus
        do {
            admitted = try await client(first).startDocumentJob(fixture.request)
            _ = try await wait(client(first), id: admitted.jobID, root: fixture.root) {
                $0.acceptedPages >= 2
            }
        } catch {
            await first.close()
            throw error
        }
        await first.close()
        let paused: DocumentJobStatus = try {
            let store = try ItemStore.openInitialized(root: fixture.store)
            return try store.documentJobStatus(admitted.jobID)
        }()
        XCTAssertEqual(paused.state, "paused")
        XCTAssertEqual(paused.reasonCode, "serverShutdown")
        let second = try await ServiceCoordinator(
            opening: fixture.store, embeddingProviderForTesting: nil, requireInitializedStore: true,
            documentRuntimeVerifierForTesting: { _ in }, documentConverter: fixture.configuration)
        do {
            let resumed = try await wait(client(second), id: admitted.jobID, root: fixture.root) {
                $0.state == "completed"
            }
            XCTAssertEqual(resumed.acceptedPages, 129)
            XCTAssertGreaterThanOrEqual(resumed.acceptedPages, paused.acceptedPages)
        } catch {
            await second.close()
            throw error
        }
        await second.close()
    }
    func testOutstandingPageTimeoutIsDurableAndDistinctFromCancellation() async throws {
        let fixture = try fixture(delay: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let resources = DocumentJobResources(
            inspectSeconds: 5, modelLoadSeconds: 5,
            pageSeconds: 0.05, noProgressSeconds: 1, terminationGraceSeconds: 0.05)
        let coordinator = try await ServiceCoordinator(
            opening: fixture.store, embeddingProviderForTesting: nil, requireInitializedStore: true,
            documentRuntimeVerifierForTesting: { _ in }, documentConverter: fixture.configuration,
            documentJobResources: resources)
        let client = client(coordinator)
        let admitted = try await client.startDocumentJob(fixture.request)
        let paused = try await wait(client, id: admitted.jobID, root: fixture.root) { $0.state == "paused" }
        XCTAssertEqual(paused.reasonCode, "documentTimeout")
        XCTAssertTrue(
            paused.reasonMessage?.contains("phase=render; timeout=page; budgetSeconds=0.05;") == true)
        let pidText = try String(
            contentsOf: fixture.root.appendingPathComponent("worker-pid"), encoding: .utf8)
        let pid = try XCTUnwrap(Int32(pidText))
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
        XCTAssertEqual(paused.acceptedPages, 1)
        XCTAssertEqual(paused.coverage.timedOut, 1)
        let page = try await client.documentJobPage(paused.jobID, pageNumber: 1)
        XCTAssertEqual(page.outcome.status, "timeout")
        await coordinator.close()
        let reopened = try ItemStore.openInitialized(root: fixture.store)
        let persisted = try reopened.documentJobStatus(paused.jobID)
        XCTAssertEqual(persisted.reasonMessage, paused.reasonMessage)
        let recordPath = fixture.store.appendingPathComponent("document-jobs/\(paused.jobID)/record.json")
        XCTAssertLessThanOrEqual(try Data(contentsOf: recordPath).count, 16 * 1024)
        let cancelled = try reopened.controlDocumentJob(
            paused.jobID, action: "cancel", configurationSHA256: "unused")
        XCTAssertNil(cancelled.reasonMessage)
    }
    func testRebuildFencesAndJoinsProducerBeforeIndexMaintenance() async throws {
        struct Start: Encodable, Sendable { let operationID: String }
        struct Job: Encodable, Sendable { let jobID: String }
        let fixture = try fixture(pages: 3, heldPage: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = try await ServiceCoordinator(
            opening: fixture.store, embeddingProviderForTesting: nil, requireInitializedStore: true,
            documentRuntimeVerifierForTesting: { _ in }, documentConverter: fixture.configuration)
        let client = client(coordinator)
        let admitted = try await client.startDocumentJob(fixture.request)
        let active = try await wait(client, id: admitted.jobID, root: fixture.root) {
            $0.acceptedPages == 1 && $0.state == "running"
        }
        XCTAssertNil(active.committed)
        let held = fixture.root.appendingPathComponent("held-page")
        for _ in 0..<300 {
            if FileManager.default.fileExists(atPath: held.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(try String(contentsOf: held, encoding: .utf8), "2")
        let pidText = try String(
            contentsOf: fixture.root.appendingPathComponent("worker-pid"), encoding: .utf8)
        let pid = try XCTUnwrap(Int32(pidText))
        XCTAssertEqual(kill(pid, 0), 0, "The held-page producer must be alive before rebuild admission")
        let gate = AdmissionGate()
        await coordinator.setRebuildAdmissionHookForTesting { await gate.pause() }
        let started = Task {
            try await client.call(
                "TractandaStore/rebuild", arguments: Start(operationID: "rebuild"),
                returning: StoreRebuildStatus.self)
        }
        try await waitForGate(gate)
        // Hold the exact admission-to-perform window until the original producer has joined.
        await coordinator.waitForDocumentProducerForTesting()
        var childStatus: Int32 = 0
        XCTAssertEqual(waitpid(pid, &childStatus, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
        let record = fixture.store.appendingPathComponent("document-jobs/\(admitted.jobID)/record.json")
        defer {
            // Keep the sealed record intact during assertions; Foundation cleanup may reject 0400.
            let descriptor = open(record.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if descriptor >= 0 {
                defer { _ = close(descriptor) }
                var metadata = stat()
                if fstat(descriptor, &metadata) == 0, metadata.st_uid == geteuid(),
                    metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), metadata.st_nlink == 1
                {
                    _ = fchmod(descriptor, (metadata.st_mode & 0o777) | mode_t(S_IWUSR))
                }
            }
        }
        let bytes = try Data(contentsOf: record)
        let persisted = try JSONDecoder().decode(DocumentJobRecord.self, from: bytes)
        XCTAssertEqual(persisted.checkpoint.acceptedPages, 1)
        XCTAssertNotEqual(persisted.checkpoint.state, "completed")
        XCTAssertFalse(
            String(decoding: bytes, as: UTF8.self).contains("serviceBusy"),
            "Admission fencing must retain the lifecycle-resumable checkpoint")
        try Data().write(to: fixture.root.appendingPathComponent("release-page"))
        await coordinator.setRebuildAdmissionHookForTesting(nil)
        await gate.release()
        var rebuild = try await started.value
        for _ in 0..<600 {
            try capacity(fixture.root)
            if rebuild.isTerminal { break }
            try await Task.sleep(for: .milliseconds(20))
            rebuild = try await client.call(
                "TractandaStore/rebuildStatus", arguments: Job(jobID: rebuild.jobID),
                returning: StoreRebuildStatus.self)
        }
        XCTAssertEqual(rebuild.state, "completed")
        XCTAssertTrue(rebuild.indexTrusted)
        let resumed = try await wait(client, id: admitted.jobID, root: fixture.root) {
            $0.state == "completed"
        }
        XCTAssertEqual(resumed.acceptedPages, 3)
        await coordinator.close()
        let reopened = try ItemStore.openInitialized(root: fixture.store)
        XCTAssertEqual(try reopened.documentJobStatus(admitted.jobID).state, "completed")
        XCTAssertEqual(try reopened.documentJobStatus(admitted.jobID).acceptedPages, 3)
    }

    private actor AdmissionGate {
        private var arrivals = 0
        private var waiter: CheckedContinuation<Void, Never>?
        func pause() async {
            arrivals += 1
            await withCheckedContinuation { waiter = $0 }
        }
        func count() -> Int { arrivals }
        func release() {
            waiter?.resume()
            waiter = nil
        }
    }
    private func waitForGate(_ gate: AdmissionGate, maximumAttempts: Int = 100) async throws {
        for _ in 0..<maximumAttempts {
            if await gate.count() > 0 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TractandaError("testTimeout", "Queued admission gate was not reached.")
    }
    func testChangedOriginalBeforeClaimPausesRatherThanStrandingQueuedJob() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = try await ServiceCoordinator(
            opening: fixture.store, embeddingProviderForTesting: nil, requireInitializedStore: true,
            documentRuntimeVerifierForTesting: { _ in }, documentConverter: fixture.configuration)
        let gate = AdmissionGate()
        await coordinator.setDocumentJobAdmissionHookForTesting { await gate.pause() }
        let client = client(coordinator)
        let admitted = try await client.startDocumentJob(fixture.request)
        try await waitForGate(gate)
        _ = try await client.detachAttachment(
            itemID: fixture.request.itemID,
            expectedRevisionID: fixture.request.expectedRevisionID,
            attachmentID: fixture.request.attachmentID, operationID: "detach-before-claim")
        await coordinator.setDocumentJobAdmissionHookForTesting(nil)
        await gate.release()
        let paused = try await wait(client, id: admitted.jobID, root: fixture.root) { $0.state == "paused" }
        XCTAssertEqual(paused.reasonCode, "documentOriginalChanged")
        XCTAssertEqual(paused.acceptedPages, 0)
        XCTAssertNil(paused.pageCount)
        await coordinator.close()
    }
    func testStaleQueuedAdmissionCannotStopExplicitResume() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = try await ServiceCoordinator(
            opening: fixture.store, embeddingProviderForTesting: nil, requireInitializedStore: true,
            documentRuntimeVerifierForTesting: { _ in }, documentConverter: fixture.configuration)
        let gate = AdmissionGate()
        do {
            await coordinator.setDocumentJobAdmissionHookForTesting { await gate.pause() }
            let client = client(coordinator)
            let admitted = try await client.startDocumentJob(fixture.request)
            try await waitForGate(gate)
            _ = try await client.cancelDocumentJob(admitted.jobID)
            let resumed = try await client.resumeDocumentJob(admitted.jobID)
            XCTAssertEqual(resumed.state, "queued")
            await coordinator.setDocumentJobAdmissionHookForTesting(nil)
            await gate.release()
            let ready = try await wait(client, id: admitted.jobID, root: fixture.root) {
                $0.state == "completed"
            }
            XCTAssertEqual(ready.acceptedPages, 129)
        } catch {
            await coordinator.setDocumentJobAdmissionHookForTesting(nil)
            await gate.release()
            await coordinator.close()
            throw error
        }
        await coordinator.close()
    }

    private final class Accounts: AccountDirectory, @unchecked Sendable {
        let alice: UInt32 = 61313
        private let lock = NSLock()
        private var deleted = false
        private var admitted = true
        func revokeGroup() {
            lock.lock()
            admitted = false
            lock.unlock()
        }
        func removeAlice() {
            lock.lock()
            deleted = true
            lock.unlock()
        }
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            lock.lock()
            let removed = deleted
            let groups: Set<UInt32> = uid != alice || admitted ? [71313] : []
            lock.unlock()
            guard uid == getuid() || (uid == alice && !removed) else {
                throw TractandaError("unresolvedPrincipal", "Fixture account disappeared.")
            }
            return AccountIdentity(
                uid: uid, name: uid == alice ? "alice" : "admin",
                primaryGroupName: "staff", groupIDs: groups)
        }
        func user(named name: String) throws -> AccountIdentity {
            guard name == "alice" || name == "admin" else {
                throw TractandaError("unresolvedPrincipal", "Unknown fixture account.")
            }
            return try user(forUID: name == "alice" ? alice : getuid())
        }
        func groupID(named name: String) throws -> UInt32 {
            guard name == "staff" else {
                throw TractandaError("unresolvedPrincipal", "Unknown fixture group.")
            }
            return 71313
        }
    }
    func testFreshGroupRevocationPreventsOffQueueJobPublication() async throws {
        let accounts = Accounts()
        let fixture = try fixture(pages: 1, accounts: accounts)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let request: DocumentJobStart = try {
            let store = try ItemStore.openInitialized(root: fixture.store, accounts: accounts)
            let shared = try store.commit(
                CommitRequest(
                    action: .revise, itemID: fixture.request.itemID,
                    expectedRevisionID: fixture.request.expectedRevisionID,
                    changes: [
                        "permissions": .object([
                            "profile": .text(ItemPermissions.profile), "owner": .text("admin"),
                            "group": .text("staff"), "mode": .integer(0o660), "acl": .object([:]),
                        ])
                    ], operationID: "share")
            ).revision
            return DocumentJobStart(
                itemID: shared.itemID, expectedRevisionID: shared.revisionID,
                attachmentID: fixture.request.attachmentID, operationID: "fresh-group")
        }()
        let coordinator = try await ServiceCoordinator(
            opening: fixture.store, embeddingProviderForTesting: nil, requireInitializedStore: true,
            documentRuntimeVerifierForTesting: { _ in }, documentConverter: fixture.configuration,
            makeAccountDirectory: { accounts })
        let gate = AdmissionGate()
        await coordinator.setDocumentJobPublicationHookForTesting { await gate.pause() }
        let alice = client(coordinator, uid: accounts.alice)
        let admin = client(coordinator)
        let admitted = try await alice.startDocumentJob(request)
        try await waitForGate(gate)
        accounts.revokeGroup()
        await coordinator.setDocumentJobPublicationHookForTesting(nil)
        await gate.release()
        let paused = try await wait(admin, id: admitted.jobID, root: fixture.root) { $0.state == "paused" }
        XCTAssertEqual(paused.reasonCode, "forbidden")
        XCTAssertNil(paused.committed)
        do {
            _ = try await alice.documentJob(admitted.jobID)
            XCTFail("Revoked account must not read retained job status")
        } catch {
            XCTAssertEqual((error as? TractandaClient.TractandaError)?.code, "forbidden")
        }
        await coordinator.close()
        let store = try ItemStore.openInitialized(root: fixture.store, accounts: accounts)
        XCTAssertNil(try store.get(request.itemID).fields["attachmentDocument"])
        XCTAssertEqual(try store.get(request.itemID).revisionID, request.expectedRevisionID)
    }

    func testQueuedDiscardAndRunningFailureFinishAfterOriginalAccountRemoval() async throws {
        let accounts = Accounts()
        let fixture = try fixture(delay: 0.05, accounts: accounts)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let request: DocumentJobStart = try {
            let store = try ItemStore.openInitialized(root: fixture.store, accounts: accounts)
            let shared = try store.commit(
                CommitRequest(
                    action: .revise, itemID: fixture.request.itemID,
                    expectedRevisionID: fixture.request.expectedRevisionID,
                    changes: [
                        "permissions": .object([
                            "profile": .text(ItemPermissions.profile),
                            "owner": .text("admin"), "group": .text("staff"),
                            "mode": .integer(0o660), "acl": .object([:]),
                        ])
                    ], operationID: "share")
            ).revision
            return DocumentJobStart(
                itemID: shared.itemID, expectedRevisionID: shared.revisionID,
                attachmentID: fixture.request.attachmentID, operationID: "active-A")
        }()
        let coordinator = try await ServiceCoordinator(
            opening: fixture.store, embeddingProviderForTesting: nil, requireInitializedStore: true,
            documentRuntimeVerifierForTesting: { _ in }, documentConverter: fixture.configuration,
            makeAccountDirectory: { accounts })
        let alice = client(coordinator, uid: accounts.alice)
        let admin = client(coordinator)
        let active = try await alice.startDocumentJob(request)
        _ = try await wait(admin, id: active.jobID, root: fixture.root) { $0.acceptedPages >= 1 }
        let queued = try await alice.startDocumentJob(
            DocumentJobStart(
                itemID: request.itemID,
                expectedRevisionID: request.expectedRevisionID, attachmentID: request.attachmentID,
                operationID: "queued-B"))
        let discarded = try await alice.discardDocumentJob(queued.jobID)
        XCTAssertTrue(discarded.discarded)
        accounts.removeAlice()
        let paused = try await wait(admin, id: active.jobID, root: fixture.root) { $0.state == "paused" }
        XCTAssertEqual(paused.reasonCode, "unresolvedPrincipal")
        XCTAssertLessThan(paused.acceptedPages, 129)
        let history = fixture.store.appendingPathComponent("document-job-history")
            .appendingPathComponent(String(queued.jobID.prefix(2))).appendingPathComponent(
                queued.jobID + ".json")
        let activeRecord = fixture.store.appendingPathComponent("document-jobs").appendingPathComponent(
            queued.jobID)
        let staged = fixture.store.appendingPathComponent("documents/.staging").appendingPathComponent(
            queued.jobID)
        for _ in 0..<200 {
            try capacity(fixture.root)
            // History is synchronized before active-record removal. Observe the complete archive,
            // not that valid intermediate step, before asserting disposal acknowledgement.
            if FileManager.default.fileExists(atPath: history.path)
                && !FileManager.default.fileExists(atPath: activeRecord.path)
                && !FileManager.default.fileExists(atPath: staged.path)
            {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: history.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: activeRecord.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        await coordinator.close()
    }

}
