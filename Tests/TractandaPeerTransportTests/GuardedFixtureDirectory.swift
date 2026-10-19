import Foundation
@testable import TractandaCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum GuardedFixtureDirectory {
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

