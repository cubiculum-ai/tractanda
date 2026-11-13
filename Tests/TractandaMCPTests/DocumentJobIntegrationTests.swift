import Foundation
import MCP
import XCTest

@testable import TractandaCore
@testable import TractandaMCP

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

// Boundary-test fixture ownership only; no product API or shared runtime state.
private enum GuardedFixtureDirectory {
    struct Context {
        let root: URL
        let proof: URL
    }
    static func physical(_ url: URL) throws -> URL {
        guard url.path.hasPrefix("/"), !url.path.contains("\0"), let path = realpath(url.path, nil) else {
            throw TractandaError("fixtureRoot", "Cannot resolve physical fixture path.")
        }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
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

final class DocumentJobIntegrationTests: XCTestCase {
    private actor PublicationGate {
        private var arrivals = 0
        private var released = false
        private var waiter: CheckedContinuation<Void, Never>?
        func pause() async {
            arrivals += 1
            guard !released else { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func arrived() -> Bool { arrivals > 0 }
        func release() {
            released = true
            waiter?.resume()
            waiter = nil
        }
    }

    private struct Fixture {
        let root: URL
        let store: URL
        let converter: DocumentConverterConfiguration
        let itemID: String
        let revisionID: String
        let attachmentID: String
        let accounts: E2EAccounts
        let operationID = "mcp-document-job"
    }

    private final class E2EAccounts: AccountDirectory, @unchecked Sendable {
        let alice: UInt32 = 80_001
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            switch uid {
            case UInt32(getuid()):
                return AccountIdentity(uid: uid, name: "admin", primaryGroupName: "staff", groupIDs: [80_003])
            case alice:
                return AccountIdentity(uid: uid, name: "alice", primaryGroupName: "staff", groupIDs: [80_003])
            default:
                throw TractandaError("unresolvedPrincipal", "Unknown fixture user.")
            }
        }
        func user(named name: String) throws -> AccountIdentity {
            switch name {
            case "admin": return try user(forUID: UInt32(getuid()))
            case "alice": return try user(forUID: alice)
            default: throw TractandaError("unresolvedPrincipal", "Unknown fixture user.")
            }
        }
        func groupID(named name: String) throws -> UInt32 {
            guard name == "staff" else {
                throw TractandaError("unresolvedPrincipal", "Unknown fixture group.")
            }
            return 80_003
        }
    }

    private func checkCapacity(at url: URL, beforeMetadata: ((URL) throws -> Void)? = nil) throws {
        for attempt in 0..<3 {
            do {
                try capacityAttempt(at: url, beforeMetadata: beforeMetadata)
                return
            } catch {
                guard attempt < 2,
                    let path = inventoryMissingPath(error), operationalInventoryPath(path, root: url)
                else { throw error }
            }
        }
    }

    /// Foundation exposes ENOENT directly, wrapped in Cocoa260, or as Cocoa260/NSURL
    /// without an underlying error. Only the named missing-file error is eligible.
    private func inventoryMissingPath(_ error: any Error) -> String? {
        let failure = error as NSError
        if failure.domain == NSPOSIXErrorDomain {
            guard failure.code == Int(ENOENT) else { return nil }
        } else {
            guard failure.domain == NSCocoaErrorDomain, failure.code == NSFileReadNoSuchFileError else {
                return nil
            }
            if let value = failure.userInfo[NSUnderlyingErrorKey] {
                let underlying: NSError
                if let native = value as? NSError {
                    underlying = native
                } else if let swift = value as? any Error {
                    underlying = swift as NSError
                } else {
                    return nil
                }
                guard underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(ENOENT) else {
                    return nil
                }
            }
        }
        let path = failure.userInfo[NSFilePathErrorKey] as? String
        let fileURL = failure.userInfo[NSURLErrorKey] as? URL
        if let fileURL, !fileURL.isFileURL { return nil }
        if let path, let fileURL, path != fileURL.path { return nil }
        return path ?? fileURL?.path
    }

    private func vanishedCheckpointByteBound(_ path: String, root: URL) -> UInt64? {
        let file = URL(fileURLWithPath: path)
        let name = file.lastPathComponent
        guard path == file.path,
            !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
                $0 == "." || $0 == ".."
            }),
            name.hasPrefix(".checkpoint-"), name.hasSuffix(".tmp"),
            UUID(uuidString: String(name.dropFirst(12).dropLast(4))) != nil
        else { return nil }
        if file.deletingLastPathComponent().path == root.appendingPathComponent("store").path {
            return 9  // StoreCheckpoint.markDirty writes nine bytes, including the newline.
        }
        let prefix = root.appendingPathComponent("store/document-jobs").path + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let parts = path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, UUID(uuidString: String(parts[0]))?.version1Components != nil else {
            return nil
        }
        // The root marker writes9bytes. replaceJobCheckpoint admits at most16KiB.
        // Charge that entire bound for each observed vanished temporary, rather than
        // restarting into another rename race or treating it as zero bytes.
        return 16 * 1024
    }

    private func operationalInventoryPath(_ path: String, root: URL) -> Bool {
        if vanishedCheckpointByteBound(path, root: root) != nil { return true }
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        if url.deletingLastPathComponent().path == root.appendingPathComponent("store").path {
            return name == ".tractanda-checkpoint-dirty"
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

    private var temporaryDirectory: URL {
        get throws { try GuardedFixtureDirectory.parent() }
    }

    private func capacityAttempt(at url: URL, beforeMetadata: ((URL) throws -> Void)?) throws {
        var values = statvfs()
        guard statvfs(url.path, &values) == 0, values.f_frsize > 0 else {
            throw TractandaError("resourceLimit", "Cannot inspect genuine fixture capacity.")
        }
        let free = UInt64(values.f_bavail).multipliedReportingOverflow(by: UInt64(values.f_frsize))
        let cap: UInt64 = 16 * 1024 * 1024
        guard !free.overflow, free.partialValue >= 10 * 1024 * 1024 * 1024 + cap else {
            throw TractandaError("resourceLimit", "Fixture needs a genuine 10 GiB reserve plus 16 MiB cap.")
        }
        if url.lastPathComponent.hasPrefix("m") {
            var owner = stat()
            guard lstat(url.path, &owner) == 0, owner.st_uid == getuid(),
                owner.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), owner.st_mode & 0o077 == 0
            else { throw TractandaError("resourceLimit", "Fixture inventory requires a private owned root.") }
            var bytes: UInt64 = 0
            if let files = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
            {
                for case let file as URL in files {
                    do {
                        try beforeMetadata?(file)
                        let metadata = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                        if metadata.isRegularFile == true { bytes += UInt64(metadata.fileSize ?? 0) }
                    } catch {
                        if let path = inventoryMissingPath(error), path != file.path {
                            throw TractandaError(
                                "fixtureInventoryMismatch",
                                "Metadata failure named a different inventory entry.")
                        }
                        var status = stat()
                        guard inventoryMissingPath(error) == file.path,
                            let bound = vanishedCheckpointByteBound(file.path, root: url),
                            lstat(file.path, &status) != 0, errno == ENOENT
                        else { throw error }
                        let unit = UInt64(values.f_frsize)
                        let rounded = bound.addingReportingOverflow(unit - 1)
                        guard !rounded.overflow else {
                            throw TractandaError(
                                "resourceLimit", "Invalid fixture allocation-unit reservation.")
                        }
                        bytes += rounded.partialValue / unit * unit
                    }
                    guard bytes <= cap else {
                        throw TractandaError("resourceLimit", "Fixture exceeded its 16 MiB cap.")
                    }
                }
            }
        }
    }

    func testOperationalInventoryRetryIsBoundedAndCanonicalLossIsNotRetried() throws {
        let root = try GuardedFixtureDirectory.create(
            prefix: "m", source: "DocumentJobIntegrationTests", test: name)
        defer { try? FileManager.default.removeItem(at: root) }
        try checkCapacity(at: root)
        try Data([1]).write(to: root.appendingPathComponent("probe"))
        let job = try UUID.makeVersion1().uuidString.lowercased()
        let session = try UUID.makeVersion1().uuidString.lowercased()
        let binding = root.appendingPathComponent(
            "store/document-jobs/" + job + "/sessions/" + session + "/binding.json"
        ).path
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: binding).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: URL(fileURLWithPath: binding))
        var attempts = 0
        XCTAssertThrowsError(
            try checkCapacity(at: root) { file in
                if file.path == binding {
                    attempts += 1
                    throw NSError(
                        domain: NSPOSIXErrorDomain, code: Int(ENOENT), userInfo: [NSFilePathErrorKey: binding]
                    )
                }
            })
        XCTAssertEqual(attempts, 3)
        attempts = 0
        XCTAssertThrowsError(
            try checkCapacity(at: root) { _ in
                attempts += 1
                throw NSError(
                    domain: NSPOSIXErrorDomain, code: Int(ENOENT),
                    userInfo: [
                        NSFilePathErrorKey: root.appendingPathComponent("store/.tractanda/revision.json").path
                    ])
            })
        XCTAssertEqual(attempts, 1)
    }

    private func missingCheckpointError(
        _ path: String, urlOnly: Bool = false, swiftUnderlying: Bool = false
    ) -> NSError {
        var info: [String: Any] = [NSURLErrorKey: URL(fileURLWithPath: path)]
        if !urlOnly {
            info[NSFilePathErrorKey] = path
            if swiftUnderlying {
                info[NSUnderlyingErrorKey] = POSIXError(.ENOENT)
            } else {
                info[NSUnderlyingErrorKey] = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
            }
        }
        return NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError, userInfo: info)
    }

    func testVanishedCheckpointTemporariesAtBothActualLocationsKeepOneBoundedInventory() throws {
        let root = try GuardedFixtureDirectory.create(
            prefix: "m", source: "DocumentJobIntegrationTests", test: name)
        defer { try? FileManager.default.removeItem(at: root) }
        let job = try UUID.makeVersion1().uuidString.lowercased()
        let parents = [
            root.appendingPathComponent("store"),
            root.appendingPathComponent("store/document-jobs/" + job),
        ]
        var targets: [String: (urlOnly: Bool, swiftUnderlying: Bool)] = [:]
        for parent in parents {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            for variant in [(false, false), (false, true), (true, false)] {
                let file = parent.appendingPathComponent(".checkpoint-" + UUID().uuidString + ".tmp")
                try Data([1]).write(to: file)
                targets[file.path] = variant
            }
        }
        let probe = root.appendingPathComponent("probe")
        try Data([1]).write(to: probe)
        var removed: Set<String> = []
        var probeVisits = 0
        try checkCapacity(at: root) { file in
            if file.path == probe.path { probeVisits += 1 }
            if let variant = targets[file.path] {
                XCTAssertTrue(removed.insert(file.path).inserted)
                try FileManager.default.removeItem(at: file)
                // Foundation may prefetch metadata on Darwin. Force the observed Linux
                // missing-file shape after an actual removal, making this deterministic.
                throw self.missingCheckpointError(
                    file.path, urlOnly: variant.urlOnly, swiftUnderlying: variant.swiftUnderlying)
            }
        }
        XCTAssertEqual(removed.count, 6)
        XCTAssertEqual(probeVisits, 1, "Checkpoint churn must not restart the complete inventory")
    }

    func testVanishedCheckpointReservationStillEnforcesSixteenMiBFixtureCap() throws {
        let root = try GuardedFixtureDirectory.create(
            prefix: "m", source: "DocumentJobIntegrationTests", test: name)
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent(
            "store/document-jobs/" + (try UUID.makeVersion1().uuidString.lowercased()))
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(".checkpoint-" + UUID().uuidString + ".tmp")
        try Data([1]).write(to: temporary)
        let stable = root.appendingPathComponent("stable-near-cap")
        let fd = open(stable.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { _ = close(fd) }
        guard ftruncate(fd, 16 * 1024 * 1024 - 8192) == 0 else { throw POSIXError(.EIO) }
        var vanished = false
        XCTAssertThrowsError(
            try checkCapacity(at: root) { file in
                if file.path == temporary.path {
                    try FileManager.default.removeItem(at: file)
                    vanished = true
                    throw self.missingCheckpointError(file.path)
                }
            }
        ) { XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit") }
        XCTAssertTrue(vanished)
    }

    func testVanishedRootMarkerReservationRoundsToFilesystemAllocationUnit() throws {
        let root = try GuardedFixtureDirectory.create(
            prefix: "m", source: "DocumentJobIntegrationTests", test: name)
        defer { try? FileManager.default.removeItem(at: root) }
        var volume = statvfs()
        guard statvfs(root.path, &volume) == 0, volume.f_frsize >= 2 else { throw POSIXError(.EIO) }
        let parent = root.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let marker = parent.appendingPathComponent(".checkpoint-" + UUID().uuidString + ".tmp")
        try Data("dirty-v1\n".utf8).write(to: marker)
        let stable = root.appendingPathComponent("stable-near-cap")
        let fd = open(stable.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { _ = close(fd) }
        guard ftruncate(fd, off_t(16 * 1024 * 1024 - UInt64(volume.f_frsize) / 2)) == 0 else {
            throw POSIXError(.EIO)
        }
        var vanished = false
        XCTAssertThrowsError(
            try checkCapacity(at: root) { file in
                if file.path == marker.path {
                    try FileManager.default.removeItem(at: file)
                    vanished = true
                    throw self.missingCheckpointError(file.path, urlOnly: true)
                }
            }
        ) { XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit") }
        XCTAssertTrue(vanished)
    }

    func testCanonicalUnknownAndPresentFilesCannotUseVanishedCheckpointAllowance() throws {
        let root = try GuardedFixtureDirectory.create(
            prefix: "m", source: "DocumentJobIntegrationTests", test: name)
        defer { try? FileManager.default.removeItem(at: root) }
        let job = try UUID.makeVersion1().uuidString.lowercased()
        for relative in [
            "store/.tractanda/revision.json", "store/document-jobs/" + job + "/record.json",
            "store/.checkpoint-not-a-uuid.tmp",
            "store/document-jobs/" + UUID().uuidString + "/.checkpoint-" + UUID().uuidString + ".tmp",
        ] {
            let target = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: target)
            var calls = 0
            XCTAssertThrowsError(
                try checkCapacity(at: root) { file in
                    if file.path == target.path {
                        calls += 1
                        try FileManager.default.removeItem(at: file)
                        throw self.missingCheckpointError(file.path, urlOnly: true)
                    }
                })
            XCTAssertEqual(calls, 1, "Canonical or unknown loss must fail without a retry")
        }
        let present = root.appendingPathComponent("store/.checkpoint-" + UUID().uuidString + ".tmp")
        try Data([1]).write(to: present)
        var calls = 0
        XCTAssertThrowsError(
            try checkCapacity(at: root) { file in
                if file.path == present.path {
                    calls += 1
                    throw self.missingCheckpointError(file.path)
                }
            })
        XCTAssertEqual(calls, 3, "An error cannot skip a checkpoint that lstat still finds")
        XCTAssertTrue(FileManager.default.fileExists(atPath: present.path))
    }

    func testWrappedCheckpointErrorsForPresentEntriesRetainThreeRescanLimit() throws {
        let root = try GuardedFixtureDirectory.create(
            prefix: "m", source: "DocumentJobIntegrationTests", test: name)
        defer { try? FileManager.default.removeItem(at: root) }
        let job = try UUID.makeVersion1().uuidString.lowercased()
        for path in [
            "store/.checkpoint-" + UUID().uuidString + ".tmp",
            "store/document-jobs/" + job + "/.checkpoint-" + UUID().uuidString + ".tmp",
        ] {
            let target = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: target)
            var attempts = 0
            XCTAssertThrowsError(
                try checkCapacity(at: root) { file in
                    if file.path == target.path {
                        attempts += 1
                        throw self.missingCheckpointError(file.path)
                    }
                })
            XCTAssertEqual(attempts, 3)
        }
    }

    func testMissingOperationalPathCannotMaskCanonicalEntryFailure() throws {
        let root = try GuardedFixtureDirectory.create(
            prefix: "m", source: "DocumentJobIntegrationTests", test: name)
        defer { try? FileManager.default.removeItem(at: root) }
        let canonical = root.appendingPathComponent("store/.tractanda/revision.json")
        try FileManager.default.createDirectory(
            at: canonical.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: canonical)
        let unrelated = root.appendingPathComponent("store/.checkpoint-" + UUID().uuidString + ".tmp")
        var calls = 0
        XCTAssertThrowsError(
            try checkCapacity(at: root) { file in
                if file.path == canonical.path {
                    calls += 1
                    try FileManager.default.removeItem(at: file)
                    throw self.missingCheckpointError(unrelated.path)
                }
            }
        ) { XCTAssertEqual(($0 as? TractandaError)?.code, "fixtureInventoryMismatch") }
        XCTAssertEqual(calls, 1)
    }

    private func fixture() throws -> Fixture {
        try checkCapacity(at: temporaryDirectory)
        let root = try GuardedFixtureDirectory.create(
            prefix: "m", source: "DocumentJobIntegrationTests", test: name)
        let storeURL = root.appendingPathComponent("store", isDirectory: true)
        let itemID: String
        let revisionID: String
        let attachmentID: String
        let accounts = E2EAccounts()
        let body = Data([0x25, 0x50, 0x44, 0x46])
        do {
            _ = try ItemStore.initializeFresh(
                root: storeURL, accounts: accounts,
                initialAccessConfiguration: .object([
                    "profile": .text(AccessConfiguration.profile),
                    "users": .list([.text("alice")]),
                ]))
            let store = try ItemStore.openInitialized(root: storeURL, accounts: accounts)
            try store.setAttachmentReserveForTesting(10 * 1024 * 1024 * 1024)
            let initial = try store.commit(
                CommitRequest(
                    classID: "Item",
                    changes: [
                        "permissions": .object([
                            "profile": .text(ItemPermissions.profile), "owner": .text("alice"),
                            "group": .text("staff"), "mode": .integer(0o640), "acl": .object([:]),
                        ])
                    ], operationID: "base-item")
            ).revision
            let upload = try store.beginAttachment(
                AttachmentUploadRequest(
                    itemID: initial.itemID, expectedRevisionID: initial.revisionID,
                    operationID: "original-upload", filename: "tiny.pdf", mediaType: "application/pdf",
                    byteCount: Int64(body.count), sha256: PageCorpusInput.digest(body)))
            let uploadID = try XCTUnwrap(upload.uploadID)
            _ = try store.appendAttachment(uploadID: uploadID, offset: 0, data: body)
            let attached = try store.finishAttachment(uploadID: uploadID).revision
            itemID = attached.itemID
            revisionID = attached.revisionID
            attachmentID = try XCTUnwrap(
                AttachmentDescriptor.descriptors(in: attached.fields).first?.attachmentID)
        }
        let worker = root.appendingPathComponent("worker.py")
        let script = """
            #!/usr/bin/python3
            import json,sys
            open(__file__+'.started','w').write('started')
            pooled=sys.argv[1]=='pool-v1'
            binding=None if pooled else json.load(open(sys.argv[5]))
            def emit(value):
                result=dict(binding);result.update(value)
                print(json.dumps(result,separators=(',',':')),flush=True)
            loaded=False
            ready=False
            if pooled:
                print(json.dumps({'workerProtocol':'tractanda.native-document-worker.v1','workerPoolProtocol':'tractanda.native-document-pool.v1'}),flush=True)
            else:
                emit({'type':'hello','pageCount':1,'modelLoaded':False,'modelForwardCalls':0})
            for line in sys.stdin:
                request=json.loads(line)
                if request['method']=='open':
                    binding=json.load(open(request['bindingPath']));ready=False
                    emit({'type':'hello','pageCount':1,'modelLoaded':loaded,'modelForwardCalls':0});continue
                if request['method']=='close':
                    emit({'type':'closed','requestID':request['requestID']})
                    if pooled:binding=None;continue
                    break
                base={'requestID':request['requestID'],'pageNumber':request['pageNumber']}
                if not ready:
                    emit(dict(base,type='progress',phase='modelReady',completed=0,total=0));loaded=True;ready=True
                emit(dict(base,type='progress',phase='render',completed=0,total=0))
                emit(dict(base,type='page',status='unsupported',failureCode='unsupportedDocumentInput'))
            """
        try Data(script.utf8).write(to: worker)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: worker.path)
        let model = root.appendingPathComponent("empty-model", isDirectory: true)
        try FileManager.default.createDirectory(
            at: model, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try checkCapacity(at: root)
        return Fixture(
            root: root, store: storeURL,
            converter: DocumentConverterConfiguration(
                executablePath: worker.path, modelDirectory: model.path,
                scratchDirectory: root.appendingPathComponent("scratch").path),
            itemID: itemID, revisionID: revisionID, attachmentID: attachmentID, accounts: accounts)
    }

    // The fixture owner removes its directory only after this scope has awaited shutdown.
    private func withCoordinator(
        fixture: Fixture, converter: Bool = false, gate: PublicationGate? = nil,
        runtimeVerifier: @escaping DocumentRuntimeVerifier = { _ in },
        body: (ServiceCoordinator) async throws -> Void
    ) async throws {
        let accounts = fixture.accounts
        // This MCP boundary fixture uses a Python wire worker rather than an admitted
        // Linux runtime. Keep the substitution local to the existing internal seam.
        let coordinator = try await ServiceCoordinator(
            opening: fixture.store, embeddingProviderForTesting: nil, requireInitializedStore: true,
            documentRuntimeVerifierForTesting: runtimeVerifier,
            documentConverter: converter ? fixture.converter : nil,
            makeAccountDirectory: { accounts })
        if let gate {
            await coordinator.setDocumentJobPublicationHookForTesting { await gate.pause() }
        }
        do {
            try await body(coordinator)
        } catch {
            await coordinator.setDocumentJobPublicationHookForTesting(nil)
            await gate?.release()
            await coordinator.close()
            throw error
        }
        await coordinator.setDocumentJobPublicationHookForTesting(nil)
        await gate?.release()
        await coordinator.close()
    }

    private func routedGateway(_ coordinator: ServiceCoordinator, uid: UInt32) -> NativeGateway {
        NativeGateway(backend: { request in
            try await coordinator.handle(request, forUID: uid)
        })
    }

    private func definition(_ name: String) throws -> ToolDefinition {
        try XCTUnwrap(ToolCatalog.definitions().first { $0.tool.name == name })
    }

    private func call(
        _ name: String, _ arguments: [String: Value], gateway: NativeGateway
    ) async throws -> Value {
        let data = try await MCPAdapter.callNativeTool(
            definition: definition(name), supplied: arguments, gateway: gateway)
        return try JSONDecoder().decode(Value.self, from: data)
    }

    private func assertForbidden(
        _ name: String, _ arguments: [String: Value], gateway: NativeGateway,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        do {
            _ = try await call(name, arguments, gateway: gateway)
            XCTFail("Expected current ACL denial for \(name).", file: file, line: line)
        } catch {
            let failure = try MCPAdapter.toolFailure(error, operationID: nil)
            XCTAssertEqual(
                failure.structuredContent?.objectValue?["code"]?.stringValue, "forbidden", file: file,
                line: line)
        }
    }

    private func waitForJob(
        _ id: String, gateway: NativeGateway, root: URL,
        until predicate: (Value) -> Bool
    ) async throws -> Value {
        for _ in 0..<600 {
            try checkCapacity(at: root)
            let status = try await call(
                "tractanda_document_job_status", ["jobID": .string(id)], gateway: gateway)
            if predicate(status) { return status }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TractandaError("testTimeout", "MCP document job did not reach its bounded fixture state.")
    }

    private func waitForPublicationGate(_ gate: PublicationGate, root: URL) async throws {
        for _ in 0..<600 {
            try checkCapacity(at: root)
            if await gate.arrived() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TractandaError("testTimeout", "Document job did not reach the publication gate.")
    }

    func testJobsRouteThroughMCPGatewayAndPublishOnlyCanonicalSavedPages() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let gate = PublicationGate()
        var jobID = ""
        try await withCoordinator(fixture: fixture, converter: true, gate: gate) { coordinator in
            let gateway = routedGateway(coordinator, uid: fixture.accounts.alice)
            let info = try await call("tractanda_info", [:], gateway: gateway)
            XCTAssertTrue(
                info.objectValue?["features"]?.arrayValue?.contains(.string("tractanda.document-jobs.v1"))
                    == true
            )

            let startArgs: [String: Value] = [
                "itemID": .string(fixture.itemID), "expectedRevisionID": .string(fixture.revisionID),
                "attachmentID": .string(fixture.attachmentID), "operationID": .string(fixture.operationID),
            ]
            let started = try await call("tractanda_document_job_start", startArgs, gateway: gateway)
            jobID = try XCTUnwrap(started.objectValue?["jobID"]?.stringValue)
            let replay = try await call("tractanda_document_job_start", startArgs, gateway: gateway)
            XCTAssertEqual(replay.objectValue?["jobID"]?.stringValue, jobID)

            try await waitForPublicationGate(gate, root: fixture.root)
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: fixture.root.appendingPathComponent("worker.py.started").path))
            let prepublication = try await call(
                "tractanda_document_job_status", ["jobID": .string(jobID)], gateway: gateway)
            XCTAssertEqual(prepublication.objectValue?["committed"], nil)
            let listed = try await call(
                "tractanda_document_jobs", ["limit": .int(16)], gateway: gateway)
            XCTAssertEqual(listed.objectValue?["jobs"]?.arrayValue?.count, 1)
            let provisional = try await call(
                "tractanda_document_job_page",
                ["jobID": .string(jobID), "pageNumber": .int(1)], gateway: gateway)
            XCTAssertEqual(provisional.objectValue?["provisional"]?.boolValue, true)
            XCTAssertNil(provisional.objectValue?["revisionID"])
            XCTAssertNil(provisional.objectValue?["citation"])
            await coordinator.setDocumentJobPublicationHookForTesting(nil)
            await gate.release()

            let done = try await waitForJob(jobID, gateway: gateway, root: fixture.root) {
                $0.objectValue?["state"]?.stringValue == "completed"
            }
            XCTAssertTrue(done.objectValue?["committed"]?.objectValue?["indexReady"]?.boolValue == true)

            let saved = try await call(
                "tractanda_attachment_document_page",
                [
                    "itemID": .string(fixture.itemID), "attachmentID": .string(fixture.attachmentID),
                    "pageNumber": .int(1),
                ], gateway: gateway)
            XCTAssertEqual(saved.objectValue?["itemID"]?.stringValue, fixture.itemID)
            XCTAssertEqual(saved.objectValue?["selectedPageNumber"]?.intValue, 1)
            XCTAssertNotNil(saved.objectValue?["revisionID"]?.stringValue)
            XCTAssertEqual(
                saved.objectValue?["outcomes"]?.arrayValue?.first?.objectValue?["pageNumber"]?.intValue, 1)
            XCTAssertEqual(
                saved.objectValue?["outcomes"]?.arrayValue?.first?.objectValue?["status"]?.stringValue,
                "unsupported")
        }

        do {
            let store = try ItemStore.openInitialized(root: fixture.store, accounts: fixture.accounts)
            _ = try store.commit(
                CommitRequest(
                    action: .revise, itemID: fixture.itemID,
                    expectedRevisionID: try XCTUnwrap(store.get(fixture.itemID).revisionID),
                    changes: [
                        "permissions": .object([
                            "profile": .text(ItemPermissions.profile), "owner": .text("admin"),
                            "group": .text("staff"), "mode": .integer(0o600), "acl": .object([:]),
                        ])
                    ], operationID: "revoke-alice"))
        }
        try await withCoordinator(fixture: fixture) { afterRevocation in
            let revokedGateway = routedGateway(afterRevocation, uid: fixture.accounts.alice)
            try await assertForbidden(
                "tractanda_attachment_document_page",
                [
                    "itemID": .string(fixture.itemID), "attachmentID": .string(fixture.attachmentID),
                    "pageNumber": .int(1),
                ], gateway: revokedGateway)
            try await assertForbidden(
                "tractanda_document_job_status", ["jobID": .string(jobID)], gateway: revokedGateway)
            try await assertForbidden(
                "tractanda_document_job_page",
                ["jobID": .string(jobID), "pageNumber": .int(1)], gateway: revokedGateway)
        }
        try checkCapacity(at: fixture.root)
    }

    func testDocumentJobFeatureIsIndependentOfConverterConfiguration() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await withCoordinator(fixture: fixture) { coordinator in
            let gateway = routedGateway(coordinator, uid: fixture.accounts.alice)
            let info = try await call("tractanda_info", [:], gateway: gateway)
            XCTAssertTrue(
                info.objectValue?["features"]?.arrayValue?.contains(.string("tractanda.document-jobs.v1"))
                    == true
            )
            let listed = try await call("tractanda_document_jobs", [:], gateway: gateway)
            XCTAssertEqual(listed.objectValue?["jobs"]?.arrayValue?.count, 0)
        }
        try checkCapacity(at: fixture.root)
    }

    func testPublicationGateReleaseBeforeArrivalIsLatched() async {
        let gate = PublicationGate()
        await gate.release()
        let finished = expectation(description: "An early release permits a later arrival")
        let arrival = Task {
            await gate.pause()
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 1)
        // Also release on failure so this regression test does not retain a suspended task.
        await gate.release()
        await arrival.value
    }

    func testHeldPublicationGateErrorAwaitsShutdownAndPreservesError() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let gate = PublicationGate()
        enum InjectedFailure: Error { case heldGate }
        do {
            try await withCoordinator(fixture: fixture, converter: true, gate: gate) { coordinator in
                let gateway = routedGateway(coordinator, uid: fixture.accounts.alice)
                _ = try await call(
                    "tractanda_document_job_start",
                    [
                        "itemID": .string(fixture.itemID),
                        "expectedRevisionID": .string(fixture.revisionID),
                        "attachmentID": .string(fixture.attachmentID),
                        "operationID": .string(fixture.operationID),
                    ], gateway: gateway)
                try await waitForPublicationGate(gate, root: fixture.root)
                throw InjectedFailure.heldGate
            }
            XCTFail("Expected the injected held-gate error.")
        } catch InjectedFailure.heldGate {
            // Reopening acquires the exclusive writer lease: shutdown finished before cleanup.
            let store = try ItemStore.openInitialized(root: fixture.store, accounts: fixture.accounts)
            XCTAssertEqual(try store.get(fixture.itemID).itemID, fixture.itemID)
        }
        try checkCapacity(at: fixture.root)
    }

    func testVerifierFailureThroughMCPPausesBeforeWorkerLaunch() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let executable = fixture.converter.executablePath
        try await withCoordinator(
            fixture: fixture, converter: true,
            runtimeVerifier: { configuration in
                guard configuration.executablePath == executable else {
                    throw TractandaError("fixtureWrongExecutable", "Verifier received a different worker")
                }
                throw TractandaError("fixtureVerifierRejected", "Injected verifier called")
            },
            body: { coordinator in
                let gateway = routedGateway(coordinator, uid: fixture.accounts.alice)
                let started = try await call(
                    "tractanda_document_job_start",
                    [
                        "itemID": .string(fixture.itemID),
                        "expectedRevisionID": .string(fixture.revisionID),
                        "attachmentID": .string(fixture.attachmentID),
                        "operationID": .string(fixture.operationID),
                    ], gateway: gateway)
                let jobID = try XCTUnwrap(started.objectValue?["jobID"]?.stringValue)
                let paused = try await waitForJob(jobID, gateway: gateway, root: fixture.root) {
                    $0.objectValue?["state"]?.stringValue == "paused"
                }
                XCTAssertEqual(paused.objectValue?["reasonCode"]?.stringValue, "fixtureVerifierRejected")
                XCTAssertFalse(
                    FileManager.default.fileExists(
                        atPath: fixture.root.appendingPathComponent("worker.py.started").path))
            }
        )
    }

}
