import CTractandaPlatform
import CTractandaSetupMetadata
import Crypto
import Foundation
import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// One explicit pre-1.0 system-layout transition. Normal startup never discovers old roots.
/// The journal contains private original receipt bytes and survives transient runtime cleanup.
struct SetupLayoutMigration {
    struct Move: Codable {
        let source: String
        let target: String
        var digest: String?
        var complete = false
        var temporaryInode: UInt64? = nil
        var temporaryDevice: UInt64? = nil
    }
    struct Journal: Codable {
        let version: Int
        let platform: String
        var phase: String
        let sourceConfig: String
        let targetConfig: String
        var moves: [Move]
        var originalFiles: [String: Data]
    }
    let engine: SetupEngine
    let legacy: SetupRoots
    private let fixtureMode: Bool
    var phaseBoundaryForTesting: ((String) throws -> Void)? = nil
    var marker: URL { engine.roots.installation.appendingPathComponent("layout-migration.json") }

    init(engine: SetupEngine, legacyForTesting: SetupRoots? = nil) {
        self.engine = engine
        fixtureMode = legacyForTesting != nil && !engine.trustedOwnership
        if let legacyForTesting {
            legacy = legacyForTesting
            return
        }
        if engine.roots.platform == .macos {
            let base = URL(fileURLWithPath: "/Users/Shared/Library/Application Support/Tractanda")
            legacy = SetupRoots(
                platform: .macos, software: base, configuration: base,
                runtime: base.appendingPathComponent("runtime"),
                data: URL(fileURLWithPath: "/Users/Shared/Library/Tractanda/Stores"),
                indexes: base.appendingPathComponent("Indexes"))
        } else {
            let base = URL(fileURLWithPath: "/etc/tractanda")
            legacy = SetupRoots(
                platform: .linux, configuration: base,
                data: URL(fileURLWithPath: "/var/lib/tractanda/stores"),
                indexes: URL(fileURLWithPath: "/var/cache/tractanda/indexes"))
        }
    }

    var mappings: [(String, String)] {
        let new = engine.roots
        var values = [
            (legacy.data.path, new.data.path), (legacy.indexes.path, new.indexes.path),
            (legacy.work.path, new.work.path), (legacy.logs.path, new.logs.path),
            (
                legacy.configuration.appendingPathComponent("receipts").path,
                new.installation.appendingPathComponent("receipts").path
            ),
            (
                legacy.configuration.appendingPathComponent("package-transaction.json").path,
                new.installation.appendingPathComponent("package-transaction.json").path
            ),
            (legacy.runtime.path, new.runtime.path),
        ]
        if new.platform == .macos {
            values += [
                (
                    legacy.software.appendingPathComponent("releases").path,
                    new.software.appendingPathComponent("releases").path
                ),
                (
                    legacy.software.appendingPathComponent("current").path,
                    new.software.appendingPathComponent("current").path
                ),
            ]
        }
        values.append((legacy.configuration.path, new.configuration.path))
        return values.sorted { $0.0.count > $1.0.count }
    }

    func translated(_ path: String) -> String {
        for (old, new) in mappings where path == old || path.hasPrefix(old + "/") {
            return new + path.dropFirst(old.count)
        }
        return path
    }

    func translatedJSON(_ value: Any) -> Any {
        if let text = value as? String { return translated(text) }
        if let list = value as? [Any] { return list.map(translatedJSON) }
        if let dictionary = value as? [String: Any] {
            return Dictionary(
                uniqueKeysWithValues: dictionary.map { (translated($0.key), translatedJSON($0.value)) })
        }
        return value
    }

    func save(_ journal: Journal) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(journal)
        guard bytes.count <= 16 * 1024 * 1024 else {
            throw SetupError("Layout journal exceeds its durable bound.")
        }
        try engine.writeProtected(bytes, to: marker, mode: 0o600)
        try engine.syncPeerReceipt(marker)
        try durableAncestors(marker.deletingLastPathComponent())
        try durableFile(marker)
    }

    func extendedMetadata(_ url: URL) throws -> [String: String] {
        let namesLength = tractanda_layout_xattr_names(url.path, nil, 0)
        guard namesLength >= 0, namesLength <= 1024 * 1024 else {
            throw SetupError("Cannot inventory relocation extended metadata.")
        }
        var names = [CChar](repeating: 0, count: Int(namesLength))
        if namesLength > 0 {
            let count = names.withUnsafeMutableBufferPointer {
                tractanda_layout_xattr_names(url.path, $0.baseAddress, $0.count)
            }
            guard count == namesLength else {
                throw SetupError("Relocation extended metadata changed during capture.")
            }
        }
        let raw = names.map { UInt8(bitPattern: $0) }
        var result: [String: String] = [:]
        for part in raw.split(separator: 0) {
            guard let name = String(bytes: part, encoding: .utf8) else {
                throw SetupError("Non-UTF8 relocation attribute name.")
            }
            let count = tractanda_layout_xattr_value(url.path, name, nil, 0)
            guard count >= 0, count <= 16 * 1024 * 1024 else {
                throw SetupError("Cannot inventory relocation attribute value.")
            }
            var bytes = [UInt8](repeating: 0, count: Int(count))
            let received = bytes.withUnsafeMutableBytes {
                tractanda_layout_xattr_value(url.path, name, $0.baseAddress, $0.count)
            }
            guard received == count else { throw SetupError("Relocation attribute changed during capture.") }
            result["xattr:" + name] = ManagedPeerConfiguration.digest(Data(bytes))
        }
        let count = tractanda_layout_acl_bytes(url.path, nil, 0)
        guard count >= 0, count <= 16 * 1024 * 1024 else {
            throw SetupError("Cannot inventory relocation ACL.")
        }
        if count > 0 {
            var bytes = [UInt8](repeating: 0, count: Int(count))
            let received = bytes.withUnsafeMutableBytes {
                tractanda_layout_acl_bytes(url.path, $0.baseAddress, $0.count)
            }
            guard received == count else { throw SetupError("Relocation ACL changed during capture.") }
            result["acl"] = ManagedPeerConfiguration.digest(Data(bytes))
        }
        return result
    }

    /// Includes all file bytes, symlink targets and Unix custody/modes. cp -a retains extended
    /// metadata; ordinary canonical/index opening is never used to manufacture a new history.
    func inventory(_ root: URL) throws -> String {
        let manager = FileManager.default
        var digest = SHA256()
        func visit(_ url: URL, relative: String) throws {
            let a = try manager.attributesOfItem(atPath: url.path)
            var row = [
                "path": relative, "uid": "\(a[.ownerAccountID]!)", "gid": "\(a[.groupOwnerAccountID]!)",
                "mode": "\(a[.posixPermissions]!)",
            ]
            row.merge(try extendedMetadata(url)) { _, _ in fatalError("Metadata keys must be disjoint") }
            switch a[.type] as? FileAttributeType {
            case .typeRegular:
                row["kind"] = "file"
                row["sha256"] = try engine.sha256(url)
                row["size"] = "\(a[.size]!)"
            case .typeSymbolicLink:
                row["kind"] = "link"
                row["target"] = try manager.destinationOfSymbolicLink(atPath: url.path)
            case .typeDirectory:
                row["kind"] = "directory"
                for child in try manager.contentsOfDirectory(atPath: url.path).sorted() {
                    try visit(url.appendingPathComponent(child), relative: relative + "/" + child)
                }
            default: throw SetupError("Special filesystem object blocks layout migration: \(url.path)")
            }
            // Length framing prevents ambiguity and keeps memory bounded by one directory
            // listing and one entry, independent of the number of canonical revisions.
            let bytes = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            digest.update(data: Data("\(bytes.count):".utf8))
            digest.update(data: bytes)
        }
        try visit(root, relative: "")
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func durableFile(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw SetupError("Cannot open relocation durability barrier: \(url.path)")
        }
        defer { close(descriptor) }
        guard tractanda_durable_sync(descriptor) == 0 else {
            throw SetupError("Relocation file durability is unproved.")
        }
    }
    func durableDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw SetupError("Cannot open relocation parent durability barrier: \(url.path)")
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw SetupError("Relocation directory durability is unproved.") }
    }
    func durableAncestors(_ directory: URL) throws {
        // Foundation may canonicalize /private/var back to /var while deleting parents.
        // Preserve the POSIX physical spelling for the no-follow directory barrier walk.
        guard let resolved = realpath(directory.path, nil) else {
            throw SetupError("Cannot resolve relocation durability parent.")
        }
        defer { free(resolved) }
        var current = String(cString: resolved)
        while current != "/" {
            let descriptor = open(current, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else {
                throw SetupError("Cannot open physical relocation durability parent: \(current)")
            }
            let result = fsync(descriptor)
            close(descriptor)
            guard result == 0 else { throw SetupError("Relocation ancestor durability is unproved.") }
            let slash = current.lastIndex(of: "/")!
            current = slash == current.startIndex ? "/" : String(current[..<slash])
        }
    }
    func durableTree(_ url: URL) throws {
        switch try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType {
        case .typeRegular: try durableFile(url)
        case .typeDirectory:
            for child in try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() {
                try durableTree(url.appendingPathComponent(child))
            }
            try durableDirectory(url)
        case .typeSymbolicLink: break  // The containing directory publishes the link itself.
        default: throw SetupError("Special filesystem object blocks relocation durability.")
        }
    }

    func relocate(_ journal: inout Journal, index: Int) throws {
        if journal.moves[index].complete { return }
        let source = URL(fileURLWithPath: journal.moves[index].source)
        let target = URL(fileURLWithPath: journal.moves[index].target)
        if journal.moves[index].digest == nil {
            guard engine.exists(source) else { throw SetupError("Missing layout source.") }
            let pinned = try inventory(source)
            // A package may already have staged its candidate beneath Software/releases.
            // Only an identical receipt-owned release leaf may coexist; never merge roots.
            if engine.exists(target) {
                let releases = legacy.software.appendingPathComponent("releases").path
                guard source.deletingLastPathComponent().path == releases,
                    try inventory(target) == pinned
                else {
                    throw SetupError("Ambiguous source/target during layout migration.")
                }
            }
            journal.moves[index].digest = pinned
            try save(journal)
        }
        let digest = journal.moves[index].digest!
        try engine.ensureRootDirectory(target.deletingLastPathComponent())
        if engine.exists(target) {
            guard try inventory(target) == digest else {
                throw SetupError("Relocated data differs from its pinned inventory.")
            }
        } else {
            guard engine.exists(source), try inventory(source) == digest else {
                throw SetupError("Layout source changed after quiescence.")
            }
            let before = try FileManager.default.attributesOfItem(atPath: source.path)
            let parent = try FileManager.default.attributesOfItem(
                atPath: target.deletingLastPathComponent().path)
            let preserveLegacyProof =
                engine.roots.platform == .linux
                && (source.lastPathComponent == "receipts"
                    || source.lastPathComponent == "package-transaction.json")
            if !preserveLegacyProof
                && before[.systemNumber] as? NSNumber == parent[.systemNumber] as? NSNumber
            {
                try FileManager.default.moveItem(at: source, to: target)
            } else {
                guard engine.roots.platform == .linux else {
                    throw SetupError("Cross-filesystem macOS relocation requires a reviewed plan.")
                }
                let temporary = URL(fileURLWithPath: target.path + ".layout-copy")
                let sourceType = before[.type] as? FileAttributeType
                if engine.exists(temporary) {
                    let metadata = try FileManager.default.attributesOfItem(atPath: temporary.path)
                    if journal.moves[index].temporaryInode == nil {
                        // Intent was durable before creation. Adopt only the untouched empty,
                        // current-root-owned placeholder at that exact protected-parent leaf.
                        let empty =
                            sourceType == .typeDirectory
                            ? try FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty
                            : ((metadata[.size] as? NSNumber)?.uint64Value == 0)
                        guard empty, !engine.isLink(temporary),
                            (metadata[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
                        else {
                            throw SetupError("Unowned interrupted layout placeholder.")
                        }
                        journal.moves[index].temporaryInode =
                            (metadata[.systemFileNumber] as? NSNumber)?.uint64Value
                        journal.moves[index].temporaryDevice =
                            (metadata[.systemNumber] as? NSNumber)?.uint64Value
                        try save(journal)
                    }
                    // Persisted st_dev is diagnostic only: reboot/remount may renumber it.
                    // The protected journal intent, exact leaf and inode/type remain the witness.
                    guard let inode = journal.moves[index].temporaryInode,
                        (metadata[.systemFileNumber] as? NSNumber)?.uint64Value == inode,
                        metadata[.type] as? FileAttributeType == sourceType
                    else {
                        throw SetupError("Unowned interrupted layout copy retained for explicit recovery.")
                    }
                } else {
                    if sourceType == .typeDirectory {
                        try FileManager.default.createDirectory(
                            at: temporary, withIntermediateDirectories: false,
                            attributes: [.posixPermissions: 0o700])
                    } else if sourceType == .typeRegular {
                        try Data().write(to: temporary, options: .withoutOverwriting)
                    } else {
                        throw SetupError("Cross-filesystem symlink relocation is unsupported.")
                    }
                    let metadata = try FileManager.default.attributesOfItem(atPath: temporary.path)
                    journal.moves[index].temporaryInode =
                        (metadata[.systemFileNumber] as? NSNumber)?.uint64Value
                    journal.moves[index].temporaryDevice = (metadata[.systemNumber] as? NSNumber)?.uint64Value
                    try save(journal)
                }
                // Replaying cp overlays only the exact journal-owned temporary inode. The full
                // source remains stopped and its pinned inventory is rechecked before retry.
                try engine.successful(
                    "/bin/cp",
                    [
                        "--archive", "--",
                        sourceType == .typeDirectory ? source.path + "/." : source.path, temporary.path,
                    ])
                guard try inventory(temporary) == digest else {
                    throw SetupError("Copied layout data failed exact byte/custody verification.")
                }
                try FileManager.default.moveItem(at: temporary, to: target)
            }
        }
        guard try inventory(target) == digest else {
            throw SetupError("Layout destination verification failed.")
        }
        // Destination bytes, metadata and both sides of rename publication become durable
        // before the durable journal may claim this move completed.
        try durableTree(target)
        try phaseBoundaryForTesting?("destinationDurable")
        try durableAncestors(target.deletingLastPathComponent())
        try durableAncestors(source.deletingLastPathComponent())
        try phaseBoundaryForTesting?("parentsDurable")
        journal.moves[index].complete = true
        try save(journal)
        try phaseBoundaryForTesting?("moveCommitted")
    }

    func validate(_ journal: Journal) throws {
        guard journal.moves.count <= 4096, journal.originalFiles.count <= 4096 else {
            throw SetupError("Layout journal inventory exceeds its bound.")
        }
        var sources = Set<String>()
        var targets = Set<String>()
        let oldReleases = legacy.software.appendingPathComponent("releases").path
        for move in journal.moves {
            let source = URL(fileURLWithPath: move.source)
            let target = URL(fileURLWithPath: move.target)
            let direct =
                mappings.contains { $0.0 == move.source && $0.1 == move.target }
                && move.source != legacy.configuration.path && move.source != legacy.runtime.path
                && !(engine.roots.platform == .macos && move.source == oldReleases)
            let release =
                engine.roots.platform == .macos && source.deletingLastPathComponent().path == oldReleases
                && move.target == translated(move.source)
            let config =
                source.deletingLastPathComponent().path == legacy.configuration.path
                && ![
                    "receipts", "package-transaction.json", "logs", "document-state", "releases", "runtime",
                    "Indexes", "current", "installer.lock",
                ].contains(source.lastPathComponent)
                && move.target
                    == (["Delivery", "uuid-node-recovery"].contains(source.lastPathComponent)
                    ? engine.roots.installation : engine.roots.configuration).appendingPathComponent(
                        source.lastPathComponent
                    ).path
            guard move.source == source.standardizedFileURL.path,
                move.target == target.standardizedFileURL.path,
                move.source != move.target, direct || release || config,
                sources.insert(move.source).inserted, targets.insert(move.target).inserted,
                move.digest.map(SetupPackageCompatibility.isDigest) ?? !move.complete,
                (move.temporaryInode == nil) == (move.temporaryDevice == nil)
            else {
                throw SetupError("Layout journal contains an unexpected relocation path or commitment.")
            }
        }
        for (path, bytes) in journal.originalFiles {
            let url = URL(fileURLWithPath: path)
            let receipt =
                url.deletingLastPathComponent().path
                == legacy.configuration.appendingPathComponent("receipts").path
                && url.pathExtension == "json"
                && SetupPackageState.validInstance(url.deletingPathExtension().lastPathComponent)
            let profile = path == legacy.configuration.appendingPathComponent("connections.json").path
            let definition =
                url.deletingLastPathComponent().path == legacy.launchDefinitions.path
                && [
                    "ai.tractanda.server.", "ai.tractanda.embeddings.", "ai.tractanda.authentication.",
                    "tractanda-server-", "tractanda-embeddings-", "tractanda-authentication-",
                ].contains(where: url.lastPathComponent.hasPrefix)
            guard path == url.standardizedFileURL.path, receipt || profile || definition,
                bytes.count <= 1024 * 1024
            else {
                throw SetupError("Layout journal contains an unexpected captured file: \(path)")
            }
        }
    }

    func run() throws -> String {
        guard engine.rootCheck(), engine.trustedOwnership || fixtureMode else {
            throw SetupError("Layout migration requires root custody.")
        }
        return try engine.withInstallerLockResult {
            try withLegacyInstallerLock { try runLocked() }
        }
    }

    func withLegacyInstallerLock<T>(_ body: () throws -> T) throws -> T {
        let config: URL
        if engine.isLink(legacy.configuration) || !engine.exists(legacy.configuration) {
            if engine.isLink(legacy.configuration) {
                guard
                    try FileManager.default.destinationOfSymbolicLink(atPath: legacy.configuration.path)
                        == engine.roots.configuration.path
                else {
                    throw SetupError("Unexpected legacy configuration alias during installer locking.")
                }
            }
            config = URL(fileURLWithPath: legacy.configuration.path + ".layout-pre20261027")
        } else {
            config = legacy.configuration
        }
        try engine.requireOwned(config, uid: 0, directory: true)
        let path = config.appendingPathComponent("installer.lock")
        if engine.exists(path) { try engine.requireOwned(path, uid: 0, directory: false) }
        let descriptor = tractanda_lock(path.path)
        guard descriptor >= 0 else { throw SetupError("An old-layout installer is already running.") }
        defer { tractanda_unlock(descriptor) }
        return try body()
    }

    private func runLocked() throws -> String {
        try engine.ensureRootDirectory(engine.roots.installation)
        var journal: Journal
        if engine.exists(marker) {
            try engine.requireOwned(marker, uid: 0, directory: false)
            guard try engine.fileSize(marker) <= 16 * 1024 * 1024 else {
                throw SetupError("Oversized layout journal.")
            }
            journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: marker))
            guard journal.version == 1, journal.platform == engine.roots.platform.rawValue,
                journal.sourceConfig == legacy.configuration.path,
                journal.targetConfig == engine.roots.configuration.path,
                ["preparing", "relocated", "committed"].contains(journal.phase)
            else {
                throw SetupError("Invalid layout migration journal.")
            }
            try validate(journal)
            if journal.phase == "committed" { return "System layout migration already committed." }
        } else {
            guard engine.exists(legacy.configuration), !engine.isLink(legacy.configuration) else {
                throw SetupError("No explicit legacy system layout to migrate.")
            }
            let old = SetupEngine(
                roots: legacy, runner: engine.runner, rootCheck: engine.rootCheck,
                trustedOwnership: engine.trustedOwnership)
            let receipts = try old.installationReceipts()
            // recoveryReason is also a retained informational diagnostic after a successful
            // stopped/policy-denied package configure. Only typed pending state blocks a move.
            guard !receipts.isEmpty,
                receipts.allSatisfy({
                    $0.state == .active && $0.peerRuntimePrevious == nil
                        && $0.embeddingPreviousConfiguration == nil
                        && $0.packageSetupOwner == nil && ($0.packageDefinitions ?? [:]).isEmpty
                })
            else {
                throw SetupError("Migration needs completed owned instances with no pending recovery.")
            }
            var originals: [String: Data] = [:]
            for receipt in receipts {
                try old.verifyRegistration(receipt)
                // Managed stop proves process incarnations exited; package preinst has normally
                // done this already on Linux. No other node is stopped by this command.
                try old.serviceBackend.unload(receipt.instance)
                try old.unloadEmbedding(receipt)
                try old.unloadAuthentication(receipt)
                _ = try old.quiescentCanonicalRequirement(receipt)
                originals[old.receiptURL(receipt.instance).path] = try Data(
                    contentsOf: old.receiptURL(receipt.instance))
                for role in [SetupServiceRole.server, .embeddings, .authentication] {
                    let definition = old.serviceBackend.definitionURL(receipt.instance, role: role)
                    if old.exists(definition) {
                        originals[definition.path] = try Data(contentsOf: definition)
                    }
                }
            }
            let profile = legacy.configuration.appendingPathComponent("connections.json")
            if old.exists(profile) { originals[profile.path] = try Data(contentsOf: profile) }
            var moves: [Move] = []
            let oldReleases = legacy.software.appendingPathComponent("releases").path
            for (source, target) in mappings
            where source != legacy.configuration.path && source != legacy.runtime.path
                && !(engine.roots.platform == .macos && source == oldReleases)
            {
                if old.exists(URL(fileURLWithPath: source)), source != target {
                    moves.append(.init(source: source, target: target))
                }
            }
            if engine.roots.platform == .macos {
                // Only software pinned by an active instance or the owned shared client is
                // needed for this relocation. Historical unreferenced payloads stay inactive.
                var needed = Set(receipts.map(\.release))
                if let client = try old.currentClientRelease() { needed.insert(client) }
                for release in needed.sorted() {
                    let source = URL(fileURLWithPath: release)
                    guard source.deletingLastPathComponent().path == oldReleases,
                        let witness = receipts.first(where: { $0.releases[release] != nil }),
                        try old.sha256(source.appendingPathComponent("bundle-manifest.json"))
                            == witness.releases[release]
                    else { throw SetupError("Unowned legacy release blocks relocation.") }
                    _ = try old.verifyBundle(at: source)
                    moves.append(.init(source: release, target: translated(release)))
                }
            }
            // Remaining protected configuration is moved entry by entry; old parents are never
            // recursively erased and no compatibility link is left in a cloud-synced Mac tree.
            let reserved = Set(
                moves.map { URL(fileURLWithPath: $0.source).lastPathComponent } + [
                    "runtime", "installer.lock", "releases",
                ])
            for child in try FileManager.default.contentsOfDirectory(atPath: legacy.configuration.path)
                .sorted()
            where !reserved.contains(child) {
                let source = legacy.configuration.appendingPathComponent(child)
                let installationOnly = ["Delivery", "uuid-node-recovery"].contains(child)
                let parent = installationOnly ? engine.roots.installation : engine.roots.configuration
                moves.append(.init(source: source.path, target: parent.appendingPathComponent(child).path))
            }
            journal = .init(
                version: 1, platform: engine.roots.platform.rawValue, phase: "preparing",
                sourceConfig: legacy.configuration.path, targetConfig: engine.roots.configuration.path,
                moves: moves, originalFiles: originals)
            try validate(journal)
            try save(journal)
        }
        let receipts = try journal.originalFiles.filter { $0.key.contains("/receipts/") }
            .sorted { $0.key < $1.key }.map {
                try JSONDecoder().decode(InstallationReceipt.self, from: $0.value)
            }
        return try withCanonicalLocks(receipts, index: 0) { try completeRelocation(&journal) }
    }

    private func withCanonicalLocks<T>(_ receipts: [InstallationReceipt], index: Int, body: () throws -> T)
        throws -> T
    {
        guard index < receipts.count else { return try body() }
        let original = URL(fileURLWithPath: receipts[index].store)
        let relocated = URL(fileURLWithPath: translated(receipts[index].store))
        let selected = engine.exists(original) ? original : relocated
        let account = try SystemAccountDirectory().user(named: engine.roots.platform.serviceUser)
        let uid =
            engine.trustedOwnership
            ? account.uid
            : ((try FileManager.default.attributesOfItem(atPath: selected.path)[.ownerAccountID] as? NSNumber)?
                .uint32Value ?? UInt32.max)
        return try CanonicalReaderRequirement.withWriterLock(root: selected, ownerUID: uid) {
            try withCanonicalLocks(receipts, index: index + 1, body: body)
        }
    }

    func completeRelocation(_ journal: inout Journal) throws -> String {
        if engine.roots.platform == .macos {
            // Keep old RunAtLoad definitions fail-closed across a reboot during relocation.
            // Normal managed installation explicitly re-enables only its owned definitions.
            for (path, bytes) in journal.originalFiles where path.contains("/receipts/") {
                let receipt = try JSONDecoder().decode(InstallationReceipt.self, from: bytes)
                guard SetupPackageState.validInstance(receipt.instance) else {
                    throw SetupError("Invalid migrated instance.")
                }
                for role in [SetupServiceRole.server, .embeddings] {
                    if role == .embeddings && receipt.embedding == nil { continue }
                    try engine.successful(
                        "/bin/launchctl",
                        ["disable", engine.serviceBackend.label(receipt.instance, role: role)])
                }
            }
        }
        if journal.phase == "preparing" {
            for index in journal.moves.indices { try relocate(&journal, index: index) }
            journal.phase = "relocated"
            try save(journal)
        }
        // Replay rewrites always start from the captured originals, never partially changed JSON.
        for (source, original) in journal.originalFiles.sorted(by: { $0.key < $1.key }) {
            let target = URL(fileURLWithPath: translated(source))
            if source.hasSuffix(".json") {
                var object = translatedJSON(try JSONSerialization.jsonObject(with: original))
                if var receipt = object as? [String: Any], receipt["instance"] != nil,
                    receipt["manifestSHA256"] != nil
                {
                    let instance = receipt["instance"] as! String
                    for (field, role) in [
                        ("definitionSHA256", SetupServiceRole.server),
                        ("embeddingDefinitionSHA256", .embeddings),
                        ("authenticationDefinitionSHA256", .authentication),
                    ] {
                        let oldPath = legacy.launchDefinitions.appendingPathComponent(
                            engine.serviceBackend.name(instance, role: role)
                                + (legacy.platform == .macos ? ".plist" : "")
                        ).path
                        if let bytes = journal.originalFiles[oldPath] {
                            receipt[field] = ManagedPeerConfiguration.digest(try rewrittenDefinition(bytes))
                        }
                    }
                    object = receipt
                }
                try engine.writeProtected(
                    JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), to: target,
                    mode: source.contains("/receipts/") ? 0o600 : 0o644)
            } else {
                try engine.writeProtected(rewrittenDefinition(original), to: target, mode: 0o644)
            }
            try engine.syncPeerReceipt(target)
            try durableFile(target)
        }
        if engine.roots.platform == .macos {
            let alias = engine.roots.software.appendingPathComponent("current")
            if engine.isLink(alias) {
                let old = try FileManager.default.destinationOfSymbolicLink(atPath: alias.path)
                let next = translated(old)
                if next != old {
                    try replaceOwnedLink(alias, old: old, new: next)
                }
            }
            for name in ["tractanda", "tractanda-tui", "tractanda-mcp", "tractanda-setup"] {
                let command = engine.roots.commands.appendingPathComponent(name)
                if engine.isLink(command) {
                    let a = try FileManager.default.attributesOfItem(atPath: command.path)
                    let old = try FileManager.default.destinationOfSymbolicLink(atPath: command.path)
                    let expected = legacy.software.appendingPathComponent("current/bin/" + name).path
                    if old == expected && (a[.ownerAccountID] as? NSNumber)?.uint32Value == 0 {
                        try replaceOwnedLink(command, old: old, new: translated(old))
                    }
                }
            }
        } else {
            // Retained originals live on their original filesystems. dpkg never owns or removes
            // them. Alias conversion occurs only after every copied byte and mode was verified.
            for (source, target) in [
                (legacy.configuration.path, engine.roots.configuration.path),
                (
                    legacy.data.deletingLastPathComponent().path,
                    engine.roots.data.deletingLastPathComponent().path
                ),
            ] {
                let url = URL(fileURLWithPath: source)
                if engine.isLink(url) {
                    guard try FileManager.default.destinationOfSymbolicLink(atPath: source) == target else {
                        throw SetupError("Unexpected public layout alias.")
                    }
                } else {
                    let retained = URL(fileURLWithPath: source + ".layout-pre20261027")
                    if engine.exists(url) {
                        guard !engine.exists(retained) else {
                            throw SetupError("Retained layout source already exists.")
                        }
                        try FileManager.default.moveItem(at: url, to: retained)
                    } else {
                        // Crash after old-root rename and before public-alias publication.
                        try engine.requireOwned(retained, uid: 0, directory: true)
                    }
                    try durableDirectory(url.deletingLastPathComponent())
                    try FileManager.default.createSymbolicLink(atPath: source, withDestinationPath: target)
                    try durableDirectory(url.deletingLastPathComponent())
                }
            }
        }
        for move in journal.moves {
            let target = URL(fileURLWithPath: move.target)
            try durableTree(target)
            try durableDirectory(target.deletingLastPathComponent())
        }
        try durableDirectory(engine.roots.configuration)
        try durableDirectory(legacy.configuration.deletingLastPathComponent())
        journal.phase = "committed"
        try save(journal)
        return "System layout relocated and verified; managed package/setup readiness is still required."
    }

    func replaceOwnedLink(_ url: URL, old: String, new: String) throws {
        let temporary = URL(fileURLWithPath: url.path + ".tractanda-layout-link")
        if engine.exists(temporary) {
            let metadata = try FileManager.default.attributesOfItem(atPath: temporary.path)
            guard engine.isLink(temporary),
                (metadata[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                try FileManager.default.destinationOfSymbolicLink(atPath: temporary.path) == new
            else {
                throw SetupError("Unowned interrupted layout link.")
            }
        } else {
            try FileManager.default.createSymbolicLink(atPath: temporary.path, withDestinationPath: new)
        }
        guard engine.isLink(url), try FileManager.default.destinationOfSymbolicLink(atPath: url.path) == old
        else {
            throw SetupError("Owned layout link changed before publication.")
        }
        guard rename(temporary.path, url.path) == 0 else {
            throw SetupError("Cannot atomically replace owned layout link.")
        }
        try durableDirectory(url.deletingLastPathComponent())
    }

    func rewrittenDefinition(_ bytes: Data) throws -> Data {
        if engine.roots.platform == .macos {
            let original = try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil)
            return try PropertyListSerialization.data(
                fromPropertyList: translatedJSON(original), format: .xml, options: 0)
        }
        guard var text = String(data: bytes, encoding: .utf8) else {
            throw SetupError("Non-UTF8 service definition.")
        }
        for (old, new) in mappings { text = text.replacingOccurrences(of: old, with: new) }
        return Data(text.utf8)
    }
}
