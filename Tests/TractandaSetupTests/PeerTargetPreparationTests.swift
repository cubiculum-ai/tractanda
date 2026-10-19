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

enum GuardedFixtureDirectory {
    struct Context {
        let root: URL
        let proof: URL
    }
    static func validate(_ url: URL) throws -> stat {
        var info = stat()
        guard url.path.hasPrefix("/"), url.path == url.standardizedFileURL.resolvingSymlinksInPath().path,
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
                throw TractandaError(
                    "resourceLimit", "Configured fixture root leaves no room for a Unix socket.")
            }
        }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        if let context {
            let actual = root.resolvingSymlinksInPath()
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

final class PeerTargetPreparationTests: XCTestCase {
    func testFiniteSameUIDPreparationRetriesWithoutInitializingOrServingPendingTarget() throws {
        guard tractanda_uid() != 0 else {
            throw XCTSkip("The finite helper requires the existing unprivileged service UID.")
        }
        let root = try GuardedFixtureDirectory.create(
            prefix: "e", source: "PeerTargetPreparationTests", test: name)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(
            at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let store = try UUID.makeVersion1().uuidString.lowercased()
        let source = try UUID.makeVersion1().uuidString.lowercased()
        let uid = tractanda_uid()
        XCTAssertThrowsError(
            try PeerTargetPreparation.run(
                root: target.path, commonStoreID: store,
                sourceReplicaID: source, requiredOwnerUID: uid == 1 ? 2 : 1))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
        // Same real UID, injected expected service UID. This does not provision an account or prove privileged cross-UID launching.
        let first = try PeerTargetPreparation.run(
            root: target.path, commonStoreID: store,
            sourceReplicaID: source, requiredOwnerUID: uid)
        XCTAssertLessThanOrEqual(first.count, 4096)
        XCTAssertEqual(
            try PeerTargetPreparation.run(
                root: target.path, commonStoreID: store,
                sourceReplicaID: source, requiredOwnerUID: uid), first)
        let preparation = try JSON.decode(PeerEnrollment.Preparation.self, first)
        XCTAssertEqual(preparation.commonStoreID, store)
        XCTAssertEqual(preparation.sourceReplicaID, source)
        XCTAssertEqual(try JSON.encode(preparation), first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("index").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("items").path))
        XCTAssertThrowsError(try ItemStore.requireInitializedRoot(target)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "enrollmentPending")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("index").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("items").path))
        XCTAssertThrowsError(
            try PeerTargetPreparation.run(
                root: target.path, commonStoreID: UUID.makeVersion1().uuidString.lowercased(),
                sourceReplicaID: source, requiredOwnerUID: uid))
        let lock = open(target.appendingPathComponent(".writer.lock").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(lock, 0)
        guard lock >= 0 else { return }
        defer { _ = close(lock) }
        XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(
            try PeerTargetPreparation.run(
                root: target.path, commonStoreID: store,
                sourceReplicaID: source, requiredOwnerUID: uid)
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "storeBusy")
        }
        XCTAssertEqual(flock(lock, LOCK_UN), 0)
        XCTAssertEqual(
            try PeerTargetPreparation.run(
                root: target.path, commonStoreID: store,
                sourceReplicaID: source, requiredOwnerUID: uid), first)
        let foreign = root.appendingPathComponent("foreign")
        try FileManager.default.createDirectory(
            at: foreign, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let content = Data("unrelated retained content".utf8)
        try content.write(to: foreign.appendingPathComponent("keep"))
        XCTAssertThrowsError(
            try PeerTargetPreparation.run(
                root: foreign.path, commonStoreID: store,
                sourceReplicaID: source, requiredOwnerUID: uid))
        XCTAssertEqual(try Data(contentsOf: foreign.appendingPathComponent("keep")), content)
    }

    func testActualBuiltSetupCommandPreparesAsItsRealNonRootOwnerAndRetriesExactly() async throws {
        guard tractanda_uid() != 0, getuid() == tractanda_uid() else {
            throw XCTSkip("The finite command requires an actual matching non-root real/effective UID.")
        }
        let root = try GuardedFixtureDirectory.create(
            prefix: "e", source: "PeerTargetPreparationTests", test: name)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(
            at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        #if os(macOS)
            let executable = Bundle(for: PeerTargetPreparationTests.self).bundleURL
                .deletingLastPathComponent().appendingPathComponent("tractanda-setup")
        #else
            let executable = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
                .appendingPathComponent("tractanda-setup")
        #endif
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: executable.path),
            "Use the just-built sibling executable, never PATH or an installed fallback.")
        let storeID = try UUID.makeVersion1().uuidString.lowercased()
        let sourceID = try UUID.makeVersion1().uuidString.lowercased()
        let arguments = ["--prepare-peer-target", target.path, storeID, sourceID]
        let launch: @Sendable () async throws -> Data = {
            try await Task.detached {
                let process = Process()
                let output = Pipe()
                let diagnostics = Pipe()
                process.executableURL = executable
                process.arguments = arguments
                process.currentDirectoryURL = root
                process.standardOutput = output
                process.standardError = diagnostics
                try process.run()
                let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
                defer { timeout.cancel() }
                // Kernel pipes stay bounded. Reap this finite, non-spawning command, then
                // read at most one byte beyond each public-output/error bound.
                process.waitUntilExit()
                let bytes = try output.fileHandleForReading.read(upToCount: 4097) ?? Data()
                let error = try diagnostics.fileHandleForReading.read(upToCount: 4097) ?? Data()
                guard process.terminationStatus == 0, bytes.count <= 4096, error.isEmpty else {
                    throw TractandaError(
                        "fixtureCommand",
                        "The just-built finite preparation command failed or exceeded its public output bound."
                    )
                }
                return bytes
            }.value
        }
        let first = try await launch()
        let second = try await launch()
        XCTAssertEqual(first, second)
        let prep = try JSON.decode(PeerEnrollment.Preparation.self, first)
        XCTAssertEqual(try JSON.encode(prep), first)
        XCTAssertEqual(prep.commonStoreID, storeID)
        XCTAssertEqual(prep.sourceReplicaID, sourceID)
        XCTAssertEqual(Set([storeID, sourceID, prep.targetReplicaID, prep.operationID]).count, 4)
        XCTAssertEqual(try FileMetadata.read(at: target).uid, tractanda_uid())
        XCTAssertThrowsError(try ItemStore.requireInitializedRoot(target)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "enrollmentPending")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("index").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("items").path))
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: target.path)),
            Set([".writer.lock", ".tractanda-enrollment.json"]))
    }
}
