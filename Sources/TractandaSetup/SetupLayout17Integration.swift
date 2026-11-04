import CTractandaPlatform
import Crypto
import Foundation
import TractandaCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Finite .17 installer bridge. Conversion belongs to the separately inventoried executable;
/// this file owns only package custody, transient administrator intent and service handoff.
struct SetupLayout17Inspection: Decodable {
    let profile: String
    let storeID: String
    let replicaID: String
    let readerRequirementSHA256: String
    let minimumReaderLevel: Int
    let clustered: Bool
    let membershipDigest: String?
    let memberCount: Int?
    let originalReaderRequirementSHA256: String?
    let currentReaderRequirementSHA256: String?
}
struct SetupLayout17Intent: Codable, Equatable {
    let profile: String
    let mode: String
    let instance: String
    let storePath: String
    let storeID: String
    let replicaID: String
    let oldManifestSHA256: String
    let newManifestSHA256: String
    let membershipDigest: String
    let readerRequirementSHA256: String
    let acknowledgedAllMembersUpgradedBeforeStart: Bool
}

extension SetupEngine {
    var layout17IntentDirectory: URL { roots.installation.appendingPathComponent("layout17-intents") }
    var layout17JournalDirectory: URL { roots.installation.appendingPathComponent("layout17-journals") }
    func layout17IntentURL(_ instance: String) -> URL {
        layout17IntentDirectory.appendingPathComponent(instance + ".json")
    }
    func layout17Declaration(_ manifest: BundleManifest, digest: String,
                             upgrade: SetupPackageCompatibility.Upgrade) throws -> SetupPackageCompatibility {
        guard let formats = manifest.canonicalFormats else {
            throw SetupError("The .17 bridge requires explicit canonical format declarations.")
        }
        return SetupPackageCompatibility(manifestSHA256: digest, version: manifest.version,
            arch: manifest.arch, canonicalFormats: formats, upgrade: upgrade,
            embedding: manifest.embedding, documentExtraction: manifest.documentExtraction)
    }
    func layout17Inspect(_ receipt: InstallationReceipt, bundle: URL,
                         resuming: Bool = false) throws -> SetupLayout17Inspection {
        if trustedOwnership {
            try requireTrustedAncestry(of: bundle)
            try requireOwned(bundle, uid: 0, directory: true)
        }
        let manifest = try verifyBundle(at: bundle)
        guard manifest.version == "0.1.0-poc.17",
            manifest.files.contains(where: { $0.path == "bin/tractanda-layout17" && $0.mode & 0o111 != 0 })
        else { throw SetupError("The verified .17 payload must include its one-time layout helper.") }
        let store = URL(fileURLWithPath: receipt.store)
        if resuming, exists(store.appendingPathComponent("canonical-layout.json")),
            !exists(store.appendingPathComponent("canonical-layout.pending.json")) {
            return try layout17CompletedInspection(receipt)
        }
        var arguments = ["inspect", "--store", receipt.store]
        if resuming { arguments += ["--journal-directory", layout17JournalDirectory.path] }
        let result = try runner.runStartup(bundle.appendingPathComponent("bin/tractanda-layout17").path,
            arguments, environment: [:])
        guard result.status == 0, result.output.utf8.count <= 65536,
            let bytes = result.output.data(using: .utf8) else {
            throw SetupError("Read-only .17 store inspection refused: " + String(result.output.prefix(4096)))
        }
        let value = try JSONDecoder().decode(SetupLayout17Inspection.self, from: bytes)
        guard value.profile == "tractanda.layout17-inspection.v1",
            SetupPackageCompatibility.isDigest(value.readerRequirementSHA256),
            (16...20).contains(value.minimumReaderLevel),
            UUID(uuidString: value.storeID)?.version1Components != nil,
            UUID(uuidString: value.replicaID)?.version1Components != nil,
            value.storeID != value.replicaID,
            !value.clustered || (value.memberCount ?? 0) > 1 && (value.memberCount ?? 257) <= 256
                && value.membershipDigest.map(SetupPackageCompatibility.isDigest) == true
        else { throw SetupError("The .17 inspection returned invalid identity or membership bindings.") }
        return value
    }
    func readLayout17Intent(_ instance: String) throws -> SetupLayout17Intent? {
        let url = layout17IntentURL(instance)
        guard exists(url) else { return nil }
        try requireOwned(url, uid: 0, directory: false)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard !isLink(url), (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
            (attributes[.referenceCount] as? NSNumber)?.intValue == 1,
            try fileSize(url) <= 65536 else { throw SetupError("Unsafe .17 administrator intent.") }
        let bytes = try Data(contentsOf: url)
        let intent = try JSONDecoder().decode(SetupLayout17Intent.self, from: bytes)
        guard bytes == (try JSON.encode(intent)), intent.profile == "tractanda.layout17-prepare.v1",
            intent.mode == "administrator-coordinated", intent.instance == instance,
            intent.acknowledgedAllMembersUpgradedBeforeStart,
            [intent.oldManifestSHA256, intent.newManifestSHA256, intent.membershipDigest,
             intent.readerRequirementSHA256].allSatisfy(SetupPackageCompatibility.isDigest)
        else { throw SetupError("Unknown or modified .17 administrator intent.") }
        return intent
    }
    func requireLayout17Intent(_ receipt: InstallationReceipt, incoming: SetupPackageCompatibility,
                               original: SetupPackageCompatibility, inspection: SetupLayout17Inspection) throws {
        guard inspection.clustered else { return }
        guard let intent = try readLayout17Intent(receipt.instance),
            intent.storePath == receipt.store, intent.storeID == inspection.storeID,
            intent.replicaID == inspection.replicaID,
            intent.oldManifestSHA256 == original.manifestSHA256,
            intent.newManifestSHA256 == incoming.manifestSHA256,
            intent.membershipDigest == inspection.membershipDigest,
            intent.readerRequirementSHA256 == inspection.readerRequirementSHA256
                || inspection.minimumReaderLevel == 20
                    && intent.readerRequirementSHA256 == inspection.originalReaderRequirementSHA256
        else {
            throw SetupError("Clustered .17 migration requires the exact transient administrator prepare intent before stopping services. Run tractanda-layout17 prepare for this instance and candidate.")
        }
    }
    func preflightLayout17Stores(_ incoming: SetupPackageCompatibility,
                                 original: SetupPackageCompatibility, bundle: URL? = nil) throws {
        try incoming.requireLayout17Transition(from: original)
        for receipt in try installationReceipts() where receipt.state != .removed {
            guard receipt.initialized else {
                throw SetupError("Finish the existing16.2 store initialization before the .17 package transition.")
            }
            let resuming = exists(URL(fileURLWithPath: receipt.store).appendingPathComponent("canonical-layout.pending.json"))
                || exists(URL(fileURLWithPath: receipt.store).appendingPathComponent("canonical-layout.json"))
            let inspection = try layout17Inspect(receipt, bundle: bundle ?? packagePayload, resuming: resuming)
            try requireLayout17Intent(receipt, incoming: incoming, original: original, inspection: inspection)
        }
    }
    /// Called after exact incoming payload verification and before any stop or state mutation.
    func requirePackageUpgrade(_ incoming: SetupPackageCompatibility,
                               from original: SetupPackageCompatibility, bundle: URL? = nil) throws {
        if incoming.version == "0.1.0-poc.17", original.version == "0.1.0-poc.17" {
            // The installed commitment was verified against the actual payload. Exact
            // reinstall does not change format or authorize releasing a held instance.
            guard incoming.upgrade == .coordinatedMaintenance, incoming == original else {
                throw SetupError("The .17 reinstall differs from the verified installed package.")
            }
            return
        }
        if incoming.version == "0.1.0-poc.17", original.version == "0.1.0-poc.16.2" {
            try preflightLayout17Stores(incoming, original: original, bundle: bundle)
        } else { try incoming.requireRollingUpgrade(from: original) }
    }
    func migrateLayout17Store(_ receipt: InstallationReceipt, bundle: URL,
                              incoming: SetupPackageCompatibility,
                              original: SetupPackageCompatibility) throws -> Bool {
        try incoming.requireLayout17Transition(from: original)
        // The external tool also takes the real canonical writer flock. Installer locking alone
        // is not quiescence, and all managed roles must already be stopped before this call.
        for role in [SetupServiceRole.server, .embeddings, .authentication] {
            guard try !serviceBackend.isRunning(receipt.instance, role: role) else {
                throw SetupError("Stop every owned role before the .17 physical migration.")
            }
        }
        let store = URL(fileURLWithPath: receipt.store)
        if exists(store.appendingPathComponent("canonical-layout.json")),
            !exists(store.appendingPathComponent("canonical-layout.pending.json")) {
            // Conversion has already committed. Startup may have accepted ordinary edits before
            // a later activation failure, so never compare its old migration snapshot again.
            let owner = try layout17StoreOwner(store)
            let marker = try layout17PrivateStoreFile(store, name: "canonical-layout.json", owner: owner)
            guard let object = try JSONSerialization.jsonObject(with: marker) as? [String: String],
                object == ["profile": "tractanda.physical-layout.v1", "layout": "flat-items-visible-attachments.v1", "recordEncoding": "message-v1"] else {
                throw SetupError("The completed .17 layout marker is invalid.")
            }
            let requirement = try quiescentCanonicalRequirement(receipt)
            guard requirement.minimumReaderLevel >= 20,
                requirement.capabilities.contains("tractanda.physical-layout.flat-items.v1"),
                requirement.capabilities.contains("tractanda.message-items.v1") else {
                throw SetupError("The completed .17 layout lost its reader fence.")
            }
            try incoming.canonicalFormats.require(requirement)
            return try readLayout17Intent(receipt.instance) != nil
        }
        let resuming = exists(store.appendingPathComponent("canonical-layout.pending.json"))
        let inspection = try layout17Inspect(receipt, bundle: bundle, resuming: resuming)
        try requireLayout17Intent(receipt, incoming: incoming, original: original, inspection: inspection)
        try ensureRootDirectory(layout17JournalDirectory)
        var arguments = ["migrate", "--store", receipt.store, "--journal-directory", layout17JournalDirectory.path]
        if inspection.clustered { arguments += ["--intent", layout17IntentURL(receipt.instance).path] }
        try successful(bundle.appendingPathComponent("bin/tractanda-layout17").path, arguments, startup: true)
        guard !exists(URL(fileURLWithPath: receipt.store).appendingPathComponent("canonical-layout.pending.json")),
            exists(URL(fileURLWithPath: receipt.store).appendingPathComponent("canonical-layout.json"))
        else { throw SetupError("The .17 external migration has not completed its durable layout barrier.") }
        return inspection.clustered
    }
    func prepareLayout17(instance: String, bundle: URL) throws -> String {
        if roots.platform == .linux { try requireLinuxPackageRoot() } else { try requireRootAndPlatform() }
        try SetupOptions(name: instance, bundle: bundle).validate()
        let manifest = try verifyBundle(at: bundle)
        let digest = try sha256(bundle.appendingPathComponent("bundle-manifest.json"))
        let incoming = try layout17Declaration(manifest, digest: digest, upgrade: .coordinatedMaintenance)
        return try withInstallerLockResult {
            guard let receipt = try readReceipt(instance), receipt.initialized, receipt.state == .active else {
                throw SetupError("Prepare requires an existing initialized owned instance.")
            }
            try verifyRegistration(receipt)
            let old = try roots.platform == .linux
                ? verifyHistoricalInstalledBundle()
                : verifyLayout17OwnedMacOriginal(receipt, release: URL(fileURLWithPath: receipt.release),
                    expectedDigest: receipt.manifestSHA256)
            guard try sha256(URL(fileURLWithPath: receipt.release).appendingPathComponent("bundle-manifest.json")) == receipt.manifestSHA256 else {
                throw SetupError("The installed source differs from its protected receipt.")
            }
            let original = try layout17Declaration(old, digest: receipt.manifestSHA256, upgrade: .compatible)
            try incoming.requireLayout17Transition(from: original)
            let inspection = try layout17Inspect(receipt, bundle: bundle)
            guard inspection.clustered, let membership = inspection.membershipDigest else {
                throw SetupError("Standalone .17 migration is automatic and needs no cluster prepare intent.")
            }
            let intent = SetupLayout17Intent(profile: "tractanda.layout17-prepare.v1",
                mode: "administrator-coordinated", instance: instance, storePath: receipt.store,
                storeID: inspection.storeID, replicaID: inspection.replicaID,
                oldManifestSHA256: original.manifestSHA256, newManifestSHA256: incoming.manifestSHA256,
                membershipDigest: membership, readerRequirementSHA256: inspection.readerRequirementSHA256,
                acknowledgedAllMembersUpgradedBeforeStart: true)
            if let old = try readLayout17Intent(instance) {
                guard old == intent else { throw SetupError("A different .17 prepare intent already exists.") }
            } else {
                try writeProtected(JSON.encode(intent), to: layout17IntentURL(instance), mode: 0o600)
                let fd = open(layout17IntentURL(instance).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw SetupError("Cannot synchronize .17 prepare intent.") }
                defer { close(fd) }
                guard tractanda_durable_sync(fd) == 0 else { throw SetupError("Cannot synchronize .17 prepare intent.") }
                try layout17SyncDirectory(layout17IntentDirectory)
            }
            try layout17StopAndDisable(receipt)
            _ = try quiescentCanonicalRequirement(receipt)
            return "Prepared and quiesced the exact .17 candidate and current membership. Keep all members stopped during package upgrades; complete --all-members-upgraded starts this instance only after every retained member is upgraded."
        }
    }
    func requireNoLayout17StartHold(_ instance: String) throws {
        if try readLayout17Intent(instance) != nil {
            throw SetupError("This clustered .17 upgrade remains stopped. After every retained member is upgraded, run tractanda-layout17 complete --instance " + instance + " --all-members-upgraded.")
        }
    }
}

extension SetupEngine {
    /// macOS retains immutable owned release roots, so a failed .17 activation can still bind
    /// the authentic .16.2 source without asking an18 reader to reopen an already fenced store.
    func layout17MacOriginal(_ previous: InstallationReceipt?, manifest: BundleManifest,
                             digest: String) throws -> SetupPackageCompatibility? {
        guard roots.platform == .macos, manifest.version == "0.1.0-poc.17", let previous else { return nil }
        let root = URL(fileURLWithPath: previous.store)
        if previous.state == .active, previous.manifestSHA256 == digest,
            try readLayout17Intent(previous.instance) == nil,
            exists(root.appendingPathComponent("canonical-layout.json")),
            !exists(root.appendingPathComponent("canonical-layout.pending.json")) { return nil }
        let incoming = try layout17Declaration(manifest, digest: digest, upgrade: .coordinatedMaintenance)
        var originals: [SetupPackageCompatibility] = []
        for (release, commitment) in previous.releases {
            let bundle = URL(fileURLWithPath: release)
            let metadata = bundle.appendingPathComponent("bundle-manifest.json")
            guard exists(metadata), try fileSize(metadata) <= 4 * 1024 * 1024 else { continue }
            let header = try JSONDecoder().decode(BundleManifest.self, from: Data(contentsOf: metadata))
            if header.version == "0.1.0-poc.16.2" {
                guard try sha256(metadata) == commitment else {
                    throw SetupError("Owned original release bytes changed during .17 recovery.")
                }
                let old = try verifyLayout17OwnedMacOriginal(previous, release: bundle, expectedDigest: commitment)
                let declaration = try layout17Declaration(old, digest: commitment, upgrade: .compatible)
                try incoming.requireLayout17Transition(from: declaration)
                originals.append(declaration)
            }
        }
        guard originals.count == 1 else {
            throw SetupError("The one-time .17 bridge requires exactly one authentic owned .16.2 source. Install .16.2 first, or resume the exact retained .17 operation.")
        }
        return originals[0]
    }
    func layout17MacPreflight(_ receipt: InstallationReceipt, bundle: URL,
                              incoming: SetupPackageCompatibility,
                              original: SetupPackageCompatibility) throws {
        let root = URL(fileURLWithPath: receipt.store)
        let inspection = try layout17Inspect(receipt, bundle: bundle,
            resuming: exists(root.appendingPathComponent("canonical-layout.pending.json"))
                || exists(root.appendingPathComponent("canonical-layout.json")))
        try requireLayout17Intent(receipt, incoming: incoming, original: original, inspection: inspection)
    }
    func layout17MayStartDuringInstallation(_ instance: String) throws -> Bool {
        try !layout17StoppedInstallation.contains(instance) && readLayout17Intent(instance) == nil
    }
    func layout17HoldInstalledMac(_ receipt: inout InstallationReceipt, clustered: Bool) throws {
        let instance = receipt.instance
        layout17StoppedInstallation.insert(instance)
        defer { layout17StoppedInstallation.remove(instance) }
        try replaceAuthenticationRegistration(&receipt)
        try replaceEmbeddingRegistration(&receipt)
        try replaceRegistration(&receipt)
        if clustered { try layout17StopAndDisable(receipt) }
        try writeGlobalProfile(receipt)
        try publishClientLink(receipt)
        try publishTUICommand()
        receipt.state = .active
        receipt.recoveryReason = clustered
            ? "The .17 layout is complete; administrator-coordinated membership remains stopped until tractanda-layout17 complete --all-members-upgraded."
            : "The .17 layout is complete; the instance retains its original stopped service intent."
        try writeReceipt(receipt)
    }
    func completeLayout17(instance: String) throws -> String {
        if roots.platform == .linux { try requireLinuxPackageRoot() } else { try requireRootAndPlatform() }
        try SetupOptions(name: instance, bundle: packagePayload).validate()
        var consumed: Data?
        try withInstallerLock {
            guard var receipt = try readReceipt(instance), receipt.initialized,
                receipt.state == .active || receipt.state == .preparing else {
                throw SetupError("No owned completed .17 cluster instance is available.")
            }
            let intent = try readLayout17Intent(instance)
            try verifyRegistration(receipt)
            let bundle = URL(fileURLWithPath: receipt.release)
            let manifest = try verifyBundle(at: bundle)
            guard manifest.version == "0.1.0-poc.17",
                try sha256(bundle.appendingPathComponent("bundle-manifest.json")) == receipt.manifestSHA256,
                intent == nil || receipt.manifestSHA256 == intent?.newManifestSHA256 && receipt.store == intent?.storePath else {
                throw SetupError("The installed .17 candidate differs from its prepare intent.")
            }
            let root = URL(fileURLWithPath: receipt.store)
            guard !exists(root.appendingPathComponent("canonical-layout.pending.json")) else {
                throw SetupError("Finish the interrupted .17 migration before releasing cluster startup.")
            }
            let owner = try layout17StoreOwner(root)
            let marker = try layout17PrivateStoreFile(root, name: "canonical-layout.json", owner: owner)
            guard let markerObject = try JSONSerialization.jsonObject(with: marker) as? [String: String],
                markerObject == ["profile": "tractanda.physical-layout.v1", "layout": "flat-items-visible-attachments.v1", "recordEncoding": "message-v1"] else {
                throw SetupError("The .17 completion marker is missing or unknown.")
            }
            let requirement = try layout17CurrentRequirement(receipt)
            guard (intent == nil || requirement.storeID == intent?.storeID), requirement.minimumReaderLevel >= 20,
                requirement.capabilities.contains("tractanda.physical-layout.flat-items.v1"),
                requirement.capabilities.contains("tractanda.message-items.v1") else {
                throw SetupError("The .17 reader fence differs from its prepared store.")
            }
            let inspection = try layout17CompletedInspection(receipt)
            guard inspection.clustered,
                intent == nil || intent?.storeID == inspection.storeID
                    && intent?.replicaID == inspection.replicaID
                    && intent?.membershipDigest == inspection.membershipDigest else {
                throw SetupError("Current membership or replica identity changed after .17 preparation.")
            }
            if receipt.state == .preparing {
                guard receipt.peerRuntimePrevious == nil, receipt.embeddingPreviousConfiguration == nil else {
                    throw SetupError("Finish pending private configuration recovery before completing .17 startup.")
                }
                if roots.platform == .linux {
                    let incoming = try layout17Declaration(manifest, digest: receipt.manifestSHA256,
                        upgrade: .coordinatedMaintenance)
                    try configureStoppedPackageInstance(&receipt, manifest: manifest, incoming: incoming)
                } else {
                    try layout17HoldInstalledMac(&receipt, clustered: true)
                }
            }
            if let intent {
                consumed = try JSON.encode(intent)
                guard unlink(layout17IntentURL(instance).path) == 0 else {
                    throw SetupError("Cannot consume the one-use .17 prepare intent.")
                }
                try layout17SyncDirectory(layout17IntentDirectory)
            }
        }
        do {
            // Explicit administrator assertion releases the start barrier. Ordinary start code
            // performs its full receipt, model, peer, canonical and runtime-readiness checks.
            try start(SetupOptions(name: instance, bundle: packagePayload))
        } catch {
            if let consumed {
                try withInstallerLock {
                    try writeProtected(consumed, to: layout17IntentURL(instance), mode: 0o600)
                    try layout17SyncDirectory(layout17IntentDirectory)
                }
            }
            throw error
        }
        return "The .17 completion acknowledgement was verified and this owned instance started. The administrator asserted that every retained member is upgraded."
    }
    func layout17StopAndDisable(_ receipt: InstallationReceipt) throws {
        try verifyRegistration(receipt)
        for role in [SetupServiceRole.server, .embeddings, .authentication] {
            guard role == .server || role == .embeddings && receipt.embedding != nil
                || role == .authentication && receipt.authenticationDefinitionSHA256 != nil else { continue }
            if roots.platform == .linux {
                try serviceBackend.disable(receipt.instance, role: role)
            } else {
                try serviceBackend.unload(receipt.instance, role: role)
                try successful("/bin/launchctl", ["disable", serviceBackend.label(receipt.instance, role: role)])
            }
            guard try !serviceBackend.isRunning(receipt.instance, role: role) else {
                throw SetupError("The .17 prepared instance is not stopped.")
            }
        }
    }
    private func layout17CompletedInspection(_ receipt: InstallationReceipt) throws -> SetupLayout17Inspection {
        let root = URL(fileURLWithPath: receipt.store)
        let owner = try layout17StoreOwner(root)
        let requirement = try layout17CurrentRequirement(receipt)
        let marker = try layout17PrivateStoreFile(root, name: "canonical-layout.json", owner: owner)
        guard let object = try JSONSerialization.jsonObject(with: marker) as? [String: String],
            object == ["profile": "tractanda.physical-layout.v1", "layout": "flat-items-visible-attachments.v1", "recordEncoding": "message-v1"],
            requirement.minimumReaderLevel >= 20,
            requirement.capabilities.contains("tractanda.physical-layout.flat-items.v1"),
            requirement.capabilities.contains("tractanda.message-items.v1") else {
            throw SetupError("The completed .17 store lost its marker or reader fence.")
        }
        let profile = try JSONSerialization.jsonObject(with:
            layout17PrivateStoreFile(root, name: ".tractanda-personal-profile.json", owner: owner)) as? [String: Any]
        guard let replica = profile?["replicaID"] as? String,
            profile?["storeID"] as? String == requirement.storeID else {
            throw SetupError("Completed .17 store identities are inconsistent.")
        }
        var membershipDigest: String?, memberCount: Int?
        if exists(root.appendingPathComponent(".personal-membership.json")) {
            let raw = try layout17PrivateStoreFile(root, name: ".personal-membership.json", owner: owner)
            let membership = try JSON.decode(PersonalMembershipConfiguration.self, raw)
            try membership.validate()
            guard membership.storeID == requirement.storeID,
                membership.members.contains(where: { $0.replicaID == replica }) else {
                throw SetupError("Completed .17 membership differs from the local store.")
            }
            membershipDigest = Self.layout17Digest(raw)
            memberCount = membership.members.count
        }
        var original: String?
        let journal = layout17JournalDirectory.appendingPathComponent("layout17-" + requirement.storeID + "-" + replica + ".json")
        if exists(journal) {
            try requireOwned(journal, uid: 0, directory: false)
            guard !isLink(journal), try fileSize(journal) <= 65536,
                let value = try JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any],
                value["profile"] as? String == "tractanda.layout17-journal.v1",
                value["storeID"] as? String == requirement.storeID,
                value["replicaID"] as? String == replica,
                let digest = value["originalRequirementSHA256"] as? String,
                SetupPackageCompatibility.isDigest(digest) else {
                throw SetupError("Completed .17 journal identity is inconsistent.")
            }
            original = digest
        }
        let current = try sha256(root.appendingPathComponent("canonical-reader.json"))
        return SetupLayout17Inspection(profile: "tractanda.layout17-inspection.v1",
            storeID: requirement.storeID, replicaID: replica, readerRequirementSHA256: original ?? current,
            minimumReaderLevel: requirement.minimumReaderLevel, clustered: (memberCount ?? 0) > 1,
            membershipDigest: membershipDigest, memberCount: memberCount,
            originalReaderRequirementSHA256: original, currentReaderRequirementSHA256: current)
    }
    private func layout17CurrentRequirement(_ receipt: InstallationReceipt) throws -> CanonicalReaderRequirement {
        let root = URL(fileURLWithPath: receipt.store)
        let owner = try layout17StoreOwner(root)
        try ItemStore.verifyPersonalWorkgroupRoot(root: root, ownerUID: owner)
        guard let value = try CanonicalReaderRequirement.load(root: root, ownerUID: owner) else {
            throw SetupError("Completed .17 reader requirement is missing.")
        }
        return value
    }
    private func layout17SyncDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SetupError("Cannot open protected .17 metadata directory.") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw SetupError("Cannot synchronize protected .17 metadata directory.") }
    }
    private static func layout17Digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    private func layout17StoreOwner(_ root: URL) throws -> UInt32 {
        if trustedOwnership { return try SystemAccountDirectory().user(named: roots.platform.serviceUser).uid }
        guard let owner = try FileManager.default.attributesOfItem(atPath: root.path)[.ownerAccountID] as? NSNumber else {
            throw SetupError("Store ownership is unavailable.")
        }
        return owner.uint32Value
    }
    private func layout17PrivateStoreFile(_ root: URL, name: String, owner: UInt32) throws -> Data {
        let descriptor = open(root.appendingPathComponent(name).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw SetupError("Missing protected .17 store metadata.") }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_uid == owner,
            metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), metadata.st_mode & 0o7777 == 0o600,
            metadata.st_nlink == 1, metadata.st_size > 0, metadata.st_size <= 128 * 1024 else {
            throw SetupError("Unsafe protected .17 store metadata.")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let bytes = try handle.readToEnd() ?? Data()
        var after = stat()
        guard fstat(descriptor, &after) == 0, bytes.count == metadata.st_size,
            after.st_ino == metadata.st_ino, after.st_size == metadata.st_size,
            after.st_mode == metadata.st_mode, after.st_uid == metadata.st_uid, after.st_nlink == 1 else {
            throw SetupError("Protected .17 store metadata changed during inspection.")
        }
        return bytes
    }
}
