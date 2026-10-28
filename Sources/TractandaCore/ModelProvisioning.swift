import CTractandaPlatform
import Crypto
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Data-only pinned artifacts, independent of embedding/index configuration identities.
public struct ModelArtifactManifest: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        public let path: String
        public let size: Int64
        public let sha256: String
        public init(path: String, size: Int64, sha256: String) {
            self.path = path
            self.size = size
            self.sha256 = sha256
        }
    }
    public let identifier: String
    public let repository: String
    public let revision: String
    public let files: [File]
    public init(identifier: String, repository: String, revision: String, files: [File]) {
        self.identifier = identifier
        self.repository = repository
        self.revision = revision
        self.files = files
    }
    public func validate() throws {
        func component(_ value: String) -> Bool {
            !value.isEmpty && value.count <= 128 && !value.hasPrefix(".")
                && value.utf8.allSatisfy {
                    (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                        || [45, 46, 95].contains($0)
                }
        }
        let repo = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard component(identifier), repo.count == 2, repo.allSatisfy({ component(String($0)) }),
            revision.count == 40,
            revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
            !files.isEmpty, files.count <= 256, Set(files.map { $0.path.lowercased() }).count == files.count
        else { throw ModelProvisioner.failure("Invalid pinned model manifest.") }
        var total: Int64 = 0
        for file in files {
            let parts = file.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.allSatisfy({ component(String($0)) }),
                ["json", "safetensors", "txt", "model", "tiktoken", "md", "jinja"].contains(
                    URL(fileURLWithPath: file.path).pathExtension),
                file.size > 0, file.size <= 16 * 1024 * 1024 * 1024,
                file.sha256.count == 64,
                file.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            else { throw ModelProvisioner.failure("Model manifest contains an unsafe file.") }
            let next = total.addingReportingOverflow(file.size)
            guard !next.overflow, next.partialValue <= 32 * 1024 * 1024 * 1024 else {
                throw ModelProvisioner.failure("Model manifest exceeds its size limit.")
            }
            total = next.partialValue
        }
    }
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
    public func directory(in root: URL) -> URL {
        root.appendingPathComponent("artifacts").appendingPathComponent(identifier).appendingPathComponent(
            revision)
    }
    /// Operational metadata stays outside the inference runtime's exact asset directory.
    public func activationMarker(in root: URL) -> URL {
        directory(in: root).deletingLastPathComponent().appendingPathComponent(revision + ".verified.json")
    }
    package func coordinationLock(in root: URL) -> URL {
        directory(in: root).deletingLastPathComponent().appendingPathComponent(revision + ".lock")
    }
    var identity: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try! encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct ModelProvisioningCatalog: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let artifacts: [ModelArtifactManifest]
    public init(artifacts: [ModelArtifactManifest]) {
        schemaVersion = 1
        self.artifacts = artifacts
    }
    public func validate() throws {
        guard schemaVersion == 1, !artifacts.isEmpty, artifacts.count <= 8,
            Set(artifacts.map { $0.identifier.lowercased() }).count == artifacts.count
        else {
            throw ModelProvisioner.failure("Invalid model catalog.")
        }
        for artifact in artifacts { try artifact.validate() }
    }
    public static func load(_ path: String) throws -> Self {
        let bytes = try ModelProvisioner.readRegular(URL(fileURLWithPath: path), limit: 1024 * 1024)
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        try value.validate()
        return value
    }
}

public struct ModelProvisioningStatus: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable {
        case waiting, checking, adopting, downloading, verifying, ready, retrying, failed, cancelled
    }
    public let artifact: String
    public let revision: String
    public let phase: Phase
    public let completedBytes: Int64
    public let totalBytes: Int64
    public let file: String?
    public let errorCode: String?
    public let observedAt: Date
}

/// Single writer per artifact across processes. Only an all-file digest check publishes activation.
/// Uses the OS curl HTTPS verifier; no remote code, shell, or total transfer timeout is involved.
public final class ModelProvisioner: @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()
    private var stopped = false
    private var process: Process?
    private var current: [String: ModelProvisioningStatus] = [:]
    private var observedArtifacts: [String: ModelArtifactManifest] = [:]
    private var persistedAt: [String: Date] = [:]
    private let reserveBytes: UInt64
    private let testingOrigin: URL?
    private let capacityForTesting: (@Sendable () throws -> UInt64)?
    public init(root: URL) {
        self.root = root
        reserveBytes = 10 * 1024 * 1024 * 1024
        testingOrigin = nil
        capacityForTesting = nil
    }
    package init(
        root: URL, testingOrigin: URL? = nil, reserveBytes: UInt64 = 10 * 1024 * 1024 * 1024,
        capacity: (@Sendable () throws -> UInt64)? = nil
    ) {
        self.root = root
        self.testingOrigin = testingOrigin
        self.reserveBytes = reserveBytes
        capacityForTesting = capacity
    }
    public func cancel() {
        lock.lock()
        stopped = true
        let child = process
        lock.unlock()
        if child?.isRunning == true { child?.terminate() }
    }
    public func status() -> [ModelProvisioningStatus] {
        lock.lock()
        let values = current.values.sorted { $0.artifact < $1.artifact }
        let artifacts = observedArtifacts
        lock.unlock()
        return values.map { value in
            if value.phase == .waiting, let artifact = artifacts[value.artifact],
                let persisted = Self.status(artifact, root: root),
                persisted.phase != .ready || Self.activated(artifact, root: root)
            {
                return persisted
            }
            return value
        }
    }
    private func checkCancellation() throws {
        lock.lock()
        let value = stopped
        lock.unlock()
        if value { throw CancellationError() }
    }
    private func update(
        _ artifact: ModelArtifactManifest, _ phase: ModelProvisioningStatus.Phase,
        bytes: Int64 = 0, file: String? = nil, error: String? = nil
    ) {
        let status = ModelProvisioningStatus(
            artifact: artifact.identifier, revision: artifact.revision,
            phase: phase, completedBytes: bytes, totalBytes: artifact.totalBytes, file: file,
            errorCode: error, observedAt: Date())
        lock.lock()
        observedArtifacts[artifact.identifier] = artifact
        let previous = current[artifact.identifier]
        current[artifact.identifier] = status
        let persist =
            previous?.phase != phase
            || Date().timeIntervalSince(persistedAt[artifact.identifier] ?? .distantPast) >= 1
        if persist { persistedAt[artifact.identifier] = Date() }
        lock.unlock()
        if persist && phase != .waiting {
            let location = root.appendingPathComponent("incoming").appendingPathComponent(artifact.identity)
                .appendingPathComponent("status.json")
            if let bytes = try? JSONEncoder().encode(status) {
                try? Self.writePrivateMetadata(bytes, to: location)
            }
        }
    }
    public static func status(_ artifact: ModelArtifactManifest, root: URL) -> ModelProvisioningStatus? {
        let location = root.appendingPathComponent("incoming").appendingPathComponent(artifact.identity)
            .appendingPathComponent("status.json")
        guard (try? ModelProvisioner(root: root).safeParents(location.deletingLastPathComponent())) != nil,
            let bytes = try? readRegular(location, limit: 16384),
            let value = try? JSONDecoder().decode(ModelProvisioningStatus.self, from: bytes),
            value.artifact == artifact.identifier, value.revision == artifact.revision,
            value.totalBytes == artifact.totalBytes, value.completedBytes >= 0,
            value.completedBytes <= value.totalBytes
        else { return nil }
        if value.phase == .ready, !activated(artifact, root: root) {
            return .init(
                artifact: artifact.identifier, revision: artifact.revision, phase: .failed,
                completedBytes: 0, totalBytes: artifact.totalBytes, file: nil,
                errorCode: "modelIntegrityUnavailable", observedAt: Date())
        }
        return value
    }
    public func provision(
        _ catalog: ModelProvisioningCatalog, adoptionDirectories: [String: URL] = [:],
        offline: Bool = false, retry: Bool = true
    ) throws {
        try catalog.validate()
        for artifact in catalog.artifacts {
            var attempt = 0
            while true {
                do {
                    try provision(
                        artifact, adopting: adoptionDirectories[artifact.identifier], offline: offline)
                    break
                } catch is CancellationError {
                    update(artifact, .cancelled)
                    throw CancellationError()
                } catch {
                    let code = (error as? TractandaError)?.code ?? "modelProvisioning"
                    update(artifact, retry && !offline ? .retrying : .failed, error: code)
                    guard retry && !offline else { throw error }
                    attempt += 1
                    let delay = min(300, 1 << min(attempt, 8))
                    for _ in 0..<(delay * 10) {
                        try checkCancellation()
                        Thread.sleep(forTimeInterval: 0.1)
                    }
                }
            }
        }
    }
    /// Marker is a local verified activation assertion, never accepted from a model download.
    public static func activated(_ artifact: ModelArtifactManifest, root: URL) -> Bool {
        let probe = ModelProvisioner(root: root)
        guard (try? probe.safeParents(artifact.directory(in: root))) != nil,
            let data = try? readRegular(artifact.activationMarker(in: root), limit: 1024 * 1024),
            let stored = try? JSONDecoder().decode(ModelArtifactManifest.self, from: data)
        else { return false }
        guard stored == artifact,
            (try? probe.verifyAssetInventory(artifact, at: artifact.directory(in: root))) != nil
        else { return false }
        for file in artifact.files {
            let url = artifact.directory(in: root).appendingPathComponent(file.path)
            var metadata = stat()
            guard (try? probe.safeParents(url.deletingLastPathComponent())) != nil,
                lstat(url.path, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                metadata.st_size == file.size, metadata.st_nlink == 1, metadata.st_mode & 0o022 == 0,
                metadata.st_uid == getuid() || metadata.st_uid == 0
            else { return false }
        }
        return true
    }
    public func isReady(_ artifact: ModelArtifactManifest) -> Bool {
        (try? verify(artifact, at: artifact.directory(in: root), markerRequired: true)) != nil
    }
    public func provision(
        _ artifact: ModelArtifactManifest, adopting source: URL? = nil, offline: Bool = false
    ) throws {
        try artifact.validate()
        try checkCancellation()
        try prepareRoot()
        let target = artifact.directory(in: root)
        try directory(target.deletingLastPathComponent())
        update(artifact, .waiting)
        let revisionFD = try acquireLock(artifact.coordinationLock(in: root))
        defer {
            _ = flock(revisionFD, LOCK_UN)
            _ = close(revisionFD)
        }
        let stage = root.appendingPathComponent("incoming").appendingPathComponent(artifact.identity)
        try directory(stage)
        let lockURL = stage.appendingPathComponent(".lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.failure("Cannot acquire model staging lock.") }
        defer { _ = close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0,
            metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), metadata.st_nlink == 1
        else {
            throw Self.failure("Unsafe model lock custody.")
        }
        update(artifact, .waiting)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN else {
                throw Self.failure("Cannot lock model stage.")
            }
            try checkCancellation()
            Thread.sleep(forTimeInterval: 0.1)
        }
        defer { _ = flock(fd, LOCK_UN) }
        update(artifact, .checking)
        let marker = artifact.activationMarker(in: root)
        if let bytes = try? Self.readRegular(marker, limit: 1024 * 1024),
            let stored = try? JSONDecoder().decode(ModelArtifactManifest.self, from: bytes),
            stored != artifact
        {
            throw Self.failure("Activated artifact identity conflicts with the configured manifest.")
        }
        if FileManager.default.fileExists(atPath: target.path) {
            try safeParents(target)
            var valid = false
            do {
                try verify(artifact, at: target, markerRequired: false)
                valid = true
            } catch is CancellationError { throw CancellationError() } catch {
                // Invalidate readiness before retaining the rejected directory. Other manifests and
                // import sources remain untouched; incomplete activation can be retried offline.
                guard unlink(marker.path) == 0 || errno == ENOENT else {
                    throw Self.failure("Cannot invalidate model readiness safely.")
                }
                let rejected = stage.appendingPathComponent("rejected-" + UUID().uuidString)
                guard rename(target.path, rejected.path) == 0 else {
                    throw Self.failure("Cannot retain an invalid model activation safely.")
                }
            }
            if valid {
                try flushVerifiedFiles(artifact, at: target)
                try syncDirectoryTree(target)
                try syncActivationDirectories(target: target, stage: stage)
                try publishMarker(artifact, marker: marker)
                update(artifact, .ready, bytes: artifact.totalBytes)
                return
            }
        }
        let payload = stage.appendingPathComponent("payload")
        try directory(payload)
        var completed: Int64 = 0
        for file in artifact.files {
            try checkCancellation()
            let output = payload.appendingPathComponent(file.path)
            try directory(output.deletingLastPathComponent())
            if (try? verify(file, at: output)) != nil {
                completed += file.size
                continue
            }
            if let source, (try? verify(file, at: source.appendingPathComponent(file.path))) != nil {
                update(artifact, .adopting, bytes: completed, file: file.path)
                let original = source.appendingPathComponent(file.path)
                try capacity(required: UInt64(file.size))
                try copy(original, to: output)
            } else {
                guard !offline else {
                    throw Self.failure("Pinned model files are missing; offline import is required.")
                }
                try download(
                    file, artifact: artifact, to: output, completed: completed, lockDescriptor: revisionFD)
            }
            update(artifact, .verifying, bytes: completed, file: file.path)
            try verify(file, at: output)
            let syncFD = open(output.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard syncFD >= 0 else { throw Self.failure("Cannot flush verified model file.") }
            let synced = fsync(syncFD)
            _ = close(syncFD)
            guard synced == 0 else { throw Self.failure("Cannot flush verified model file.") }
            completed += file.size
        }
        try checkCancellation()
        try verify(artifact, at: payload, markerRequired: false)
        try directory(target.deletingLastPathComponent())
        try syncDirectoryTree(payload)
        guard rename(payload.path, target.path) == 0 else {
            throw Self.failure("Cannot atomically activate verified model data.")
        }
        try syncActivationDirectories(target: target, stage: stage)
        // This atomic marker publish is the final readiness commit, after durable data.
        try publishMarker(artifact, marker: marker)
        // Rejected model data is derived and is retained until its replacement is durably active.
        for entry in try FileManager.default.contentsOfDirectory(at: stage, includingPropertiesForKeys: nil)
        where entry.lastPathComponent.hasPrefix("rejected-") {
            try FileManager.default.removeItem(at: entry)
        }
        update(artifact, .ready, bytes: artifact.totalBytes)
    }
    private func download(
        _ file: ModelArtifactManifest.File, artifact: ModelArtifactManifest, to output: URL, completed: Int64,
        lockDescriptor: Int32
    ) throws {
        var meta = stat()
        if lstat(output.path, &meta) == 0 {
            guard meta.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), meta.st_uid == getuid(),
                meta.st_nlink == 1
            else {
                throw Self.failure("Unsafe partial model file.")
            }
            if meta.st_size >= file.size { try FileManager.default.removeItem(at: output) }
        }
        let existing =
            (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value
            ?? 0
        try capacity(required: UInt64(max(64 * 1024, file.size - existing)))
        let url: URL
        if let testingOrigin {
            url = testingOrigin.appendingPathComponent(file.path)
        } else {
            url = URL(
                string:
                    "https://huggingface.co/\(artifact.repository)/resolve/\(artifact.revision)/\(file.path)")!
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        child.arguments = [
            "--fail", "--silent", "--show-error", "--location", "--max-redirs", "8",
            "--proto", testingOrigin == nil ? "=https" : "=http,https", "--proto-redir",
            testingOrigin == nil ? "=https" : "=http,https",
            // curl also applies this header ceiling to redirect bodies. Small HuggingFace
            // metadata can have a larger redirect body; output bytes and final digest stay exact.
            "--connect-timeout", "30", "--max-filesize", String(max(file.size, 64 * 1024)),
            "--continue-at", "-", "--output", output.path, url.absoluteString,
        ]
        // The child shares the locked open-file description through fd0. Its fixed arguments
        // never read stdin. Even abrupt owner death cannot admit another writer while curl lives.
        child.standardInput = FileHandle(fileDescriptor: lockDescriptor, closeOnDealloc: false)
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        // No user curlrc, proxy credentials or executable search through PATH.
        child.arguments!.insert("--disable", at: 0)
        child.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path]
        lock.lock()
        process = child
        lock.unlock()
        defer {
            lock.lock()
            process = nil
            lock.unlock()
        }
        try child.run()
        do {
            while child.isRunning {
                try checkCancellation()
                try capacity(required: 0)
                let size =
                    (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?
                    .int64Value ?? 0
                guard size <= file.size else {
                    throw Self.failure("Model transfer exceeded its pinned size.")
                }
                update(artifact, .downloading, bytes: completed + size, file: file.path)
                Thread.sleep(forTimeInterval: 0.1)
            }
        } catch {
            stopOwnedTransfer(child)
            throw error
        }
        child.waitUntilExit()
        try checkCancellation()
        guard child.terminationStatus == 0 else {
            // curl33 means the server did not honor the resume range; keep no ambiguous prefix.
            if child.terminationStatus == 33 { try? FileManager.default.removeItem(at: output) }
            throw Self.failure(
                "Pinned model transfer failed (curl \(child.terminationStatus)); verified activation remains unavailable."
            )
        }
    }
    /// Explicit cancellation/resource failure only: a blocked/ignored SIGTERM cannot leave an
    /// owned writer alive. This grace is never a transfer idle deadline or total download timeout.
    private func stopOwnedTransfer(_ child: Process) {
        if child.isRunning {
            child.terminate()
            let stop = ContinuousClock.now.advanced(by: .seconds(2))
            while child.isRunning && ContinuousClock.now < stop { Thread.sleep(forTimeInterval: 0.02) }
            if child.isRunning { _ = kill(child.processIdentifier, SIGKILL) }
        }
        child.waitUntilExit()
    }
    private func copy(_ source: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw Self.failure("Cannot open model import.") }
        let reader = FileHandle(fileDescriptor: input, closeOnDealloc: true)
        defer { try? reader.close() }
        let output = open(destination.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw Self.failure("Cannot create model import stage.") }
        let writer = FileHandle(fileDescriptor: output, closeOnDealloc: true)
        defer { try? writer.close() }
        while let bytes = try reader.read(upToCount: 1024 * 1024), !bytes.isEmpty {
            try checkCancellation()
            try capacity(required: UInt64(bytes.count))
            try writer.write(contentsOf: bytes)
        }
        try writer.synchronize()
    }
    private func verify(_ artifact: ModelArtifactManifest, at url: URL, markerRequired: Bool) throws {
        try safeParents(url)
        try verifyAssetInventory(artifact, at: url)
        if markerRequired {
            let marker = try Self.readRegular(
                url.deletingLastPathComponent().appendingPathComponent(
                    url.lastPathComponent + ".verified.json"), limit: 1024 * 1024)
            guard try JSONDecoder().decode(ModelArtifactManifest.self, from: marker) == artifact else {
                throw Self.failure("Model activation identity differs.")
            }
        }
        for file in artifact.files {
            try checkCancellation()
            try verify(file, at: url.appendingPathComponent(file.path))
        }
    }
    private func acquireLock(_ url: URL) throws -> Int32 {
        let fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.failure("Cannot open model revision lock.") }
        do {
            var metadata = stat()
            guard fstat(fd, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                metadata.st_uid == getuid(), metadata.st_nlink == 1, metadata.st_mode & 0o077 == 0
            else {
                throw Self.failure("Unsafe model revision lock custody.")
            }
            while flock(fd, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK || errno == EAGAIN else {
                    throw Self.failure("Cannot lock model revision.")
                }
                try checkCancellation()
                Thread.sleep(forTimeInterval: 0.1)
            }
            return fd
        } catch {
            _ = close(fd)
            throw error
        }
    }
    private func verifyAssetInventory(_ artifact: ModelArtifactManifest, at root: URL) throws {
        let expected = Set(artifact.files.map(\.path))
        var found = Set<String>()
        var pending: [(URL, String)] = [(root, "")]
        var entries = 0
        while let (directory, prefix) = pending.popLast() {
            try checkCancellation()
            let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw Self.failure("Model asset directory is unavailable or a symlink.") }
            let handle = tractanda_directory_open_fd(fd)
            _ = close(fd)
            guard let handle else { throw Self.failure("Cannot enumerate model assets safely.") }
            defer { _ = tractanda_directory_close(handle) }
            var name = [CChar](repeating: 0, count: 1024)
            let capacity = name.count
            while true {
                let next = tractanda_directory_next(handle, &name, capacity)
                guard next >= 0 else { throw Self.failure("Cannot enumerate model assets safely.") }
                if next == 0 { break }
                entries += 1
                guard entries <= 4096 else { throw Self.failure("Model asset inventory exceeds its bound.") }
                let component = String(cString: name)
                let path = prefix + component
                let child = directory.appendingPathComponent(component)
                var metadata = stat()
                guard lstat(child.path, &metadata) == 0 else {
                    throw Self.failure("Model asset inventory changed.")
                }
                if metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                    guard metadata.st_uid == getuid() || metadata.st_uid == 0, metadata.st_mode & 0o022 == 0
                    else { throw Self.failure("Unsafe model asset directory custody.") }
                    pending.append((child, path + "/"))
                } else {
                    guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), expected.contains(path),
                        found.insert(path).inserted
                    else {
                        throw Self.failure(
                            "Model directory must contain exactly the pinned inference assets, without metadata or symlinks."
                        )
                    }
                }
            }
        }
        guard found == expected else { throw Self.failure("Model asset inventory is incomplete.") }
    }
    private func flushVerifiedFiles(_ artifact: ModelArtifactManifest, at directory: URL) throws {
        for file in artifact.files {
            let fd = open(directory.appendingPathComponent(file.path).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw Self.failure("Cannot flush verified model data.") }
            let result = fsync(fd)
            _ = close(fd)
            guard result == 0 else { throw Self.failure("Cannot flush verified model data.") }
        }
    }
    private func publishMarker(_ artifact: ModelArtifactManifest, marker: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try Self.writePrivateMetadata(encoder.encode(artifact), to: marker)
    }
    private func verify(_ file: ModelArtifactManifest.File, at url: URL) throws {
        try safeParents(url.deletingLastPathComponent())
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Self.failure("Pinned model file is unavailable.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            metadata.st_size == file.size,
            metadata.st_nlink == 1, metadata.st_mode & 0o022 == 0,
            metadata.st_uid == getuid() || metadata.st_uid == 0
        else {
            throw Self.failure("Pinned model file has wrong size or custody.")
        }
        var hash = SHA256()
        var count: Int64 = 0
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try checkCancellation()
            count += Int64(data.count)
            guard count <= file.size else { throw Self.failure("Model file changed during verification.") }
            hash.update(data: data)
        }
        guard count == file.size, hash.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256
        else {
            throw Self.failure("Pinned model checksum differs.")
        }
    }
    private func prepareRoot() throws {
        guard root.path.hasPrefix("/"), root.path != "/", !root.path.contains("\0"),
            root.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".."
            })
        else { throw Self.failure("Choose a dedicated absolute model root.") }
        try directory(root)
        try directory(root.appendingPathComponent("incoming"))
        try directory(root.appendingPathComponent("artifacts"))
    }
    private func directory(_ url: URL) throws {
        if url.path != root.path, url.path.hasPrefix(root.path + "/"),
            !FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path)
        {
            try directory(url.deletingLastPathComponent())
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            try safeParents(url.deletingLastPathComponent())
            guard mkdir(url.path, 0o700) == 0 || errno == EEXIST else {
                throw Self.failure("Cannot create model directory.")
            }
        }
        try safeParents(url)
        var meta = stat()
        guard lstat(url.path, &meta) == 0, meta.st_uid == getuid(), meta.st_mode & 0o077 == 0 else {
            throw Self.failure("Model directory must be private and service-owned.")
        }
    }
    private func safeParents(_ url: URL) throws {
        var current = URL(fileURLWithPath: "/")
        for part in url.pathComponents.dropFirst() {
            current.appendPathComponent(part)
            var meta = stat()
            guard lstat(current.path, &meta) == 0, meta.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                meta.st_uid == 0 || meta.st_uid == getuid(),
                meta.st_mode & 0o022 == 0 || meta.st_mode & mode_t(S_ISVTX) != 0
            else {
                throw Self.failure("Model path contains unsafe directory custody or symlink.")
            }
        }
    }
    private func syncActivationDirectories(target: URL, stage: URL) throws {
        try syncDirectory(target.deletingLastPathComponent())
        try syncDirectory(root.appendingPathComponent("artifacts"))
        try syncDirectory(stage)
        try syncDirectory(root.appendingPathComponent("incoming"))
        try syncDirectory(root)
    }
    private func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Self.failure("Cannot open model directory for durability.") }
        defer { _ = close(fd) }
        guard fsync(fd) == 0 else { throw Self.failure("Cannot flush model directory activation.") }
    }
    private func syncDirectoryTree(_ url: URL) throws {
        for entry in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            var metadata = stat()
            guard lstat(entry.path, &metadata) == 0 else {
                throw Self.failure("Model stage changed before activation.")
            }
            if metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) { try syncDirectoryTree(entry) }
        }
        try syncDirectory(url)
    }
    private func capacity(required: UInt64) throws {
        let available: UInt64
        if let capacityForTesting {
            available = try capacityForTesting()
        } else {
            var stats = statvfs()
            guard statvfs(root.path, &stats) == 0 else {
                throw Self.failure("Cannot determine model filesystem capacity.")
            }
            let result = UInt64(stats.f_bavail).multipliedReportingOverflow(by: UInt64(stats.f_frsize))
            guard !result.overflow else { throw Self.failure("Cannot determine model filesystem capacity.") }
            available = result.partialValue
        }
        let needed = reserveBytes.addingReportingOverflow(required)
        guard !needed.overflow, available >= needed.partialValue else {
            throw TractandaError(
                "resourceLimit", "Model provisioning preserves a genuine 10 GiB filesystem reserve.")
        }
    }
    static func readRegular(_ url: URL, limit: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure("Cannot open model metadata.") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var meta = stat()
        guard fstat(fd, &meta) == 0, meta.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), meta.st_size <= limit,
            meta.st_mode & 0o022 == 0, meta.st_uid == 0 || meta.st_uid == getuid()
        else { throw failure("Unsafe model metadata custody or size.") }
        let bytes = try file.read(upToCount: limit + 1) ?? Data()
        guard bytes.count <= limit else { throw failure("Model metadata exceeds its limit.") }
        return bytes
    }
    /// Publish small operational metadata with a mode independent of the caller's umask.
    /// The temporary is created beside the destination so rename is atomic on one filesystem.
    static func writePrivateMetadata(_ bytes: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw failure("Invalid model metadata path.")
        }
        let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw failure("Cannot open model metadata directory safely.") }
        defer { _ = close(parentFD) }
        let directoryURL = parent.standardizedFileURL
        try ModelProvisioner(root: directoryURL).safeParents(directoryURL)
        var parentMetadata = stat()
        guard fstat(parentFD, &parentMetadata) == 0,
            parentMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
            parentMetadata.st_uid == getuid() || parentMetadata.st_uid == 0,
            parentMetadata.st_mode & 0o022 == 0 || parentMetadata.st_mode & mode_t(S_ISVTX) != 0
        else {
            throw failure("Unsafe model metadata directory custody.")
        }

        var existing = stat()
        if fstatat(parentFD, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard existing.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), existing.st_nlink == 1,
                existing.st_uid == getuid() || existing.st_uid == 0
            else {
                throw failure("Unsafe existing model metadata custody.")
            }
        } else if errno != ENOENT {
            throw failure("Cannot inspect existing model metadata safely.")
        }

        let temporary = "." + name + "." + UUID().uuidString + ".tmp"
        let descriptor = temporary.withCString {
            openat(parentFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard descriptor >= 0 else { throw failure("Cannot create private model metadata temporary.") }
        var published = false
        defer {
            if !published { _ = temporary.withCString { unlinkat(parentFD, $0, 0) } }
            _ = close(descriptor)
        }
        var created = stat()
        guard fstat(descriptor, &created) == 0, created.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            created.st_uid == getuid(), created.st_nlink == 1, fchmod(descriptor, 0o600) == 0
        else {
            throw failure("Cannot establish private model metadata custody.")
        }
        try bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let amount = write(descriptor, base.advanced(by: offset), raw.count - offset)
                if amount < 0 && errno == EINTR { continue }
                guard amount > 0 else { throw failure("Cannot write model metadata completely.") }
                offset += amount
            }
        }
        var written = stat()
        guard fstat(descriptor, &written) == 0, written.st_mode & 0o777 == 0o600,
            written.st_uid == getuid(), written.st_nlink == 1, fsync(descriptor) == 0
        else {
            throw failure("Cannot flush private model metadata.")
        }
        let renamed = temporary.withCString { temp in
            name.withCString { destination in renameat(parentFD, temp, parentFD, destination) }
        }
        guard renamed == 0 else { throw failure("Cannot atomically publish model metadata.") }
        published = true
        guard fsync(parentFD) == 0 else { throw failure("Cannot flush model metadata directory.") }
    }
    static func failure(_ message: String) -> TractandaError { TractandaError("modelProvisioning", message) }
}
