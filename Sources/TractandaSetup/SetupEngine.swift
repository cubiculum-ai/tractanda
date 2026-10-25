import CTractandaPlatform
import Crypto
import Foundation
import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// The macOS preview reuses daemon. It owns installation receipts and software, while
/// canonical data remains service-owned and survives uninstall. Linux program files are dpkg-owned;
/// its public installation path requires the committed complete package transaction.
public final class SetupEngine {
    public let roots: SetupRoots
    var serviceBackend: SetupServiceBackend {
        var backend = SetupServiceBackend(roots: roots, runner: runner)
        backend.allowFixtureRuntimeRoot = !trustedOwnership
        return backend
    }
    let runner: any SetupProcessRunning
    let rootCheck: () -> Bool
    let trustedOwnership: Bool
    let readinessCheck: ((String, String, Int) throws -> Void)?
    let peerStatusCall: (String, String) throws -> PeerOperatorRuntimeStatus
    let semanticCall: (String, String, String, [String: Any]) throws -> [String: Any]
    // Internal fixture seams, never command-line overrides or canonical authority.
    var packageOwnerIdentity: () throws -> SetupPackageOwner = { try SetupPackageOwner.current() }
    var packageOwnerIsLive: (SetupPackageOwner) -> Bool = { $0.isLive() }
    var packageAuthenticationReadiness: ((InstallationReceipt) throws -> Void)?
    var packageStartPolicy: ((String) throws -> Bool)?
    var packagePreparedVerification: ((InstallationReceipt, String, String) throws -> Void)?
    var packageDefinitionMutation: ((String, SetupServiceRole, Bool) throws -> Void)?

    public init(
        roots: SetupRoots = SetupRoots(), runner: any SetupProcessRunning = FoundationProcessRunner(),
        rootCheck: @escaping () -> Bool = { getuid() == 0 }, trustedOwnership: Bool = true,
        peerStatusCall: ((String, String) throws -> PeerOperatorRuntimeStatus)? = nil,
        readinessCheck: ((String, String, Int) throws -> Void)? = nil,
        semanticCall: ((String, String, String, [String: Any]) throws -> [String: Any])? = nil
    ) {
        self.roots = roots
        self.runner = runner
        self.rootCheck = rootCheck
        self.trustedOwnership = trustedOwnership
        self.readinessCheck = readinessCheck
        self.peerStatusCall =
            peerStatusCall ?? { socket, user in
                try SetupNativeClient(socket: socket, serverUser: user).peerRuntimeStatus()
            }
        self.semanticCall =
            semanticCall ?? { socket, user, method, arguments in
                try SetupNativeClient(socket: socket, serverUser: user).call(method, arguments)
            }
    }

    public func plan(_ options: SetupOptions) throws -> SetupPlan {
        try options.validate()
        if roots.platform == .macos, options.storeSelection != .unconfigured {
            throw SetupError("Linux store selection cannot be planned for macOS.")
        }
        try ServerConnection(
            socketPath: roots.runtime.appendingPathComponent(options.name).appendingPathComponent(
                "server.sock"
            ).path
        ).validate()
        try validateRoots()
        let manifest = try verifyBundle(at: options.bundle)
        let release = releaseURL(
            options, manifest: manifest,
            digest: try sha256(options.bundle.appendingPathComponent("bundle-manifest.json")))
        return SetupPlan(
            instance: options.name, store: roots.data.appendingPathComponent(options.name).path,
            indexDirectory: roots.indexes.appendingPathComponent(options.name).path,
            socket: roots.runtime.appendingPathComponent(options.name).appendingPathComponent("server.sock")
                .path,
            definition: definitionURL(options.name).path,
            executable: release.appendingPathComponent("bin/tractanda").path,
            actions: roots.platform == .macos
                ? [
                    "Verify the release and protected parent directories",
                    "Use the existing daemon account; create no accounts",
                    "Initialize an empty store or optional owner-private sample data",
                    "Register boot-time system LaunchDaemons",
                    "Verify native/HTTP readiness before publishing client connection settings",
                    try peerPlanAction(options),
                ]
                : [
                    "Require a committed complete architecture-specific Debian package",
                    "Use the existing daemon account; create no accounts",
                    "Choose standalone initialization or validate independently pinned prepared-replica adoption",
                    "Register owned systemd services with a protected package startup guard",
                    "Verify native, authentication, bundled component and peer configuration readiness",
                ])
    }

    public func install(_ options: SetupOptions, upgrade: Bool = false) throws {
        if roots.platform == .linux {
            try requireLinuxPackageRoot()
            try requireNoPendingPackageMutation()
            guard let state = try readPackageState(), state.phase == .committed,
                let incoming = state.incoming,
                incoming.manifestSHA256 == (try installedPackageCompatibility()).manifestSHA256,
                options.bundle.standardizedFileURL.path == packagePayload.path
            else {
                throw SetupError(
                    "Install the complete verified .deb before selecting or reconfiguring a Linux instance.")
            }
            if try readReceipt(options.name) == nil, options.storeSelection == .unconfigured {
                throw SetupError(
                    "Choose --first-source or --adopt-prepared with independent store/replica pins; package installation never chooses for a joining host."
                )
            }
            try install(options, upgrade: upgrade, packageOperationID: nil, explicitLinux: true)
        } else {
            guard options.storeSelection == .unconfigured else {
                throw SetupError("Explicit Linux store selection is unavailable on macOS.")
            }
            try install(options, upgrade: upgrade, packageOperationID: nil)
        }
    }

    func installForPackage(_ options: SetupOptions, operationID: String) throws {
        try install(options, upgrade: true, packageOperationID: operationID)
    }

    private func install(
        _ options: SetupOptions, upgrade: Bool, packageOperationID: String?, explicitLinux: Bool = false
    ) throws {
        if packageOperationID != nil || explicitLinux {
            try requireLinuxPackageRoot()
        } else {
            try requireRootAndPlatform()
            try requireNoPendingPackageMutation()
        }
        try options.validate()
        try ServerConnection(
            socketPath: roots.runtime.appendingPathComponent(options.name).appendingPathComponent(
                "server.sock"
            ).path
        ).validate()
        let capturedPeerBytes: Data?
        if case .replace(let input) = options.peerRuntime {
            capturedPeerBytes = try capturePeerConfiguration(input)
        } else {
            capturedPeerBytes = nil
        }
        let plannedReceipt = try readReceipt(options.name)
        let dataParent =
            plannedReceipt.map { URL(fileURLWithPath: $0.store).deletingLastPathComponent() } ?? roots.data
        let indexParent =
            plannedReceipt.map { URL(fileURLWithPath: $0.indexDirectory).deletingLastPathComponent() }
            ?? roots.indexes
        try validateRoots(data: dataParent, indexes: indexParent)
        let manifest = try verifyBundle(at: options.bundle)
        let digest = try sha256(options.bundle.appendingPathComponent("bundle-manifest.json"))
        // Inspect all ancestry before creating even the software/configuration directories.
        if trustedOwnership {
            for path in [
                roots.software, roots.configuration, roots.launchDefinitions, dataParent, indexParent,
                roots.runtime,
            ] {
                try requireTrustedAncestry(of: path)
            }
        }
        try ensureRootDirectory(roots.configuration)
        try withPackageInstallerLock(packageOperationID) {
            let oldClientRelease = try currentClientRelease()
            let previous = try readReceipt(options.name)
            guard previous == plannedReceipt else {
                throw SetupError("Installation state changed; retry the command.")
            }
            if roots.platform == .linux {
                guard try sha256(packagePayload.appendingPathComponent("bundle-manifest.json")) == digest,
                    try verifyBundle(at: packagePayload) == manifest
                else { throw SetupError("Active package changed before installation serialization.") }
                if let previous {
                    switch options.storeSelection {
                    case .unconfigured: break
                    case .standalone:
                        guard previous.preparedStoreID == nil else {
                            throw SetupError(
                                "A prepared replica cannot be reclassified as a standalone source.")
                        }
                    case .prepared(let storeID, let replicaID):
                        guard previous.preparedStoreID == storeID, previous.preparedReplicaID == replicaID
                        else {
                            throw SetupError(
                                "Prepared identity selection differs from the retained installation pins.")
                        }
                    }
                }
            }
            if let previous, previous.state == .active, previous.manifestSHA256 != digest, !upgrade {
                throw SetupError("This instance already has another release. Use upgrade.")
            }
            let owner = try previous?.owner ?? resolvedOwner(options)
            if let requested = options.owner, requested != owner {
                throw SetupError("An upgrade cannot replace the initial owner.")
            }
            let account = try SystemAccountDirectory().user(named: roots.platform.serviceUser)
            guard account.uid != 0 else { throw SetupError("The server account must be unprivileged.") }
            let release = releaseURL(options, manifest: manifest, digest: digest)
            if let old = previous?.embedding, manifest.embedding != old,
                !isSupportedBundledEmbeddingTransition(from: old, to: manifest.embedding)
            {
                throw SetupError(
                    "This installation needs its existing embedding payload; this bundled embedding transition requires an explicit reconfiguration."
                )
            }
            if previous?.documentExtraction != nil && manifest.documentExtraction == nil {
                throw SetupError("An upgrade cannot silently remove the configured document payload.")
            }
            if manifest.embedding != nil && (previous?.port ?? options.port) == 65535 {
                throw SetupError(
                    "Choose an HTTP port below 65535 so the local embedding service has a separate port.")
            }
            var receipt =
                try previous
                ?? InstallationReceipt(
                    options: options, roots: roots, owner: owner, release: release, manifestSHA256: digest)
            let peerTransition = try preparePeerTransition(
                previous: previous, options: options,
                captured: capturedPeerBytes, uid: account.uid)
            receipt.peerRuntimeConfiguration = peerTransition.desired
            receipt.peerRuntimePrevious = peerTransition.previous
            if previous == nil {
                if roots.platform == .linux,
                    case .prepared(let storeID, let replicaID) = options.storeSelection
                {
                    try prepareExplicitReplicaAdoption(
                        &receipt, storeID: storeID, replicaID: replicaID, uid: account.uid)
                } else {
                    for path in [
                        receipt.store, receipt.indexDirectory,
                        URL(fileURLWithPath: receipt.socket).deletingLastPathComponent().path,
                    ] {
                        guard !exists(URL(fileURLWithPath: path)) else {
                            throw SetupError("Refusing to adopt an existing path: \(path)")
                        }
                    }
                }
                guard !exists(definitionURL(options.name)) else {
                    throw SetupError("A service definition already exists without an owned receipt.")
                }
                try ensureNoGlobalProfile(options.name)
            } else {
                try verifyRegistration(receipt)
                if trustedOwnership {
                    for path in [receipt.store, receipt.indexDirectory] {
                        try requireServiceDirectory(URL(fileURLWithPath: path), uid: account.uid)
                    }
                }
            }
            for path in [
                roots.software, roots.launchDefinitions, dataParent, indexParent, roots.runtime,
                roots.configuration.appendingPathComponent("logs"),
            ] { try ensureRootDirectory(path) }
            if previous == nil { try writeReceipt(receipt) }
            try installRelease(manifest, from: options.bundle, to: release, digest: digest)
            if var tracked = previous {
                tracked.releases[release.path] = digest
                try writeReceipt(tracked)
            }
            for path in [receipt.store, receipt.indexDirectory] {
                try ensureServiceDirectory(URL(fileURLWithPath: path), uid: account.uid, mode: 0o700)
            }
            try ensureServiceDirectory(
                URL(fileURLWithPath: receipt.socket).deletingLastPathComponent(), uid: account.uid,
                mode: 0o711)
            try ensureServiceLog(receipt.instance, uid: account.uid)
            if manifest.embedding != nil {
                try ensureServiceLog(receipt.instance + "-embeddings", uid: account.uid)
            }
            let embeddingUpgrade =
                previous.flatMap { previous in
                    guard let old = previous.embedding, old != manifest.embedding else { return false }
                    return isSupportedBundledEmbeddingTransition(from: old, to: manifest.embedding)
                } ?? false
            if embeddingUpgrade { try prepareBundledEmbeddingUpgrade(&receipt) }
            receipt.documentExtraction = manifest.documentExtraction
            try prepareDocumentState(&receipt, uid: account.uid)
            receipt.embedding = manifest.embedding
            receipt.release = release.path
            receipt.manifestSHA256 = digest
            receipt.releases[release.path] = digest
            receipt.state = .preparing
            if explicitLinux { receipt.packageSetupOwner = try packageOwnerIdentity() }
            if !receipt.initialized {
                try writeReceipt(receipt)
                let executable = release.appendingPathComponent("bin/tractanda-setup").path
                var command = ["-n", "-u", roots.platform.serviceUser, "--", "/usr/bin/env"]
                if let node = receipt.uuidNode { command.append("TRACTANDA_UUID_NODE=" + node) }
                command += [
                    executable, "--bootstrap-store", receipt.store, receipt.indexDirectory, receipt.owner,
                    receipt.instance,
                ]
                try successful("/usr/bin/sudo", command, startup: true)
                receipt.initialized = true
                try writeReceipt(receipt)
            }
            let definition = definitionURL(receipt.instance)
            let oldDefinition = exists(definition) ? try Data(contentsOf: definition) : nil
            let embeddingDefinition = embeddingDefinitionURL(receipt.instance)
            let oldEmbeddingDefinition =
                exists(embeddingDefinition) ? try Data(contentsOf: embeddingDefinition) : nil
            if previous?.embedding == nil && receipt.embedding != nil && oldEmbeddingDefinition != nil {
                throw SetupError("An embedding service definition already exists without an owned receipt.")
            }
            let oldProfiles = try globalProfilesSnapshot()
            let oldSemanticConfiguration = receipt.embeddingPreviousConfiguration
            var profilesPublished = false
            var clientsPublished = false
            do {
                // Durable desired/prior commitments precede publication. Old daemon is stopped
                // and the canonical writer guard is acquired before changing its loaded file.
                try writeReceipt(receipt)
                try unload(receipt.instance)
                try requireCanonicalReader(receipt, quiescent: true)
                if receipt.peerRuntimeConfiguration != nil {
                    try publishPeerBytes(
                        peerTransition.bytes, replacing: peerTransition.currentBytes,
                        instance: receipt.instance, uid: account.uid)
                }
                try replaceAuthenticationRegistration(&receipt)
                try replaceEmbeddingRegistration(&receipt)
                try replaceRegistration(&receipt)
                try waitUntilReady(receipt)
                if receipt.sample && !receipt.sampled {
                    receipt.board = try SetupNativeClient(
                        socket: receipt.socket, serverUser: roots.platform.serviceUser
                    )
                    .seed(owner: receipt.owner, instance: receipt.instance, release: release)
                    receipt.sampled = true
                    try writeReceipt(receipt)
                    try replaceRegistration(&receipt)
                    try waitUntilReady(receipt)
                }
                try configureEmbedding(&receipt)
                try writeGlobalProfile(receipt)
                profilesPublished = true
                try publishClientLink(receipt)
                clientsPublished = true
                try publishTUICommand()
                if receipt.peerRuntimeConfiguration == nil {
                    try publishPeerBytes(
                        nil, replacing: peerTransition.currentBytes,
                        instance: receipt.instance, uid: account.uid)
                }
                _ = try ownedPeerBytes(
                    receipt.peerRuntimeConfiguration, instance: receipt.instance, uid: account.uid)
                receipt.state = .active
                receipt.packageSetupOwner = nil
                receipt.peerRuntimePrevious = nil
                receipt.embeddingPreviousConfiguration = nil
                try writeReceipt(receipt)
            } catch {
                receipt.peerRuntimePrevious = peerTransition.previous
                var semanticRollbackError: Error?
                if let oldSemanticConfiguration {
                    do {
                        // The native server owns semantic.json; restore through its compare-and-swap
                        // while it is still running. Restoring after unload would silently strand the
                        // previous embedding profile against the candidate runtime.
                        if try semanticConfigurationSnapshot(receipt) != oldSemanticConfiguration {
                            try restoreSemanticConfiguration(oldSemanticConfiguration, after: receipt)
                        }
                    } catch {
                        semanticRollbackError = error
                    }
                }
                try? unload(receipt.instance)
                try? unloadEmbedding(receipt)
                try? unloadAuthentication(receipt)
                if roots.platform == .linux {
                    receipt.state = .preparing
                    receipt.packageSetupOwner = nil
                    receipt.recoveryReason =
                        "Package configuration failed against the actual dpkg-owned payload; no old program was restored. "
                        + error.localizedDescription
                    if let semanticRollbackError {
                        receipt.recoveryReason! +=
                            " Semantic recovery also failed: " + semanticRollbackError.localizedDescription
                    }
                    try writeReceipt(receipt)
                    throw SetupError(receipt.recoveryReason!)
                }
                do {
                    if let previous, previous.state == .active {
                        try requireCanonicalReader(previous, quiescent: true)
                    }
                } catch {
                    try blockCanonicalRollback(&receipt, error: error)
                    throw SetupError(
                        "Installation failed; canonical compatibility blocks rollback. Services remain stopped, the preparing receipt and all data/backups are retained. "
                            + error.localizedDescription)
                }
                if profilesPublished { try? restoreGlobalProfiles(oldProfiles) }
                if let semanticRollbackError {
                    let serverDisabled = removeOwnedRegistration(
                        definition, expectedSHA256: receipt.definitionSHA256)
                    let embeddingDisabled = removeOwnedRegistration(
                        embeddingDefinition, expectedSHA256: receipt.embeddingDefinitionSHA256)
                    receipt.state = .preparing
                    receipt.embeddingConfigured = false
                    receipt.definitionSHA256 = nil
                    receipt.embeddingDefinitionSHA256 = nil
                    try writeReceipt(receipt)
                    let definitions =
                        serverDisabled && embeddingDisabled
                        ? "Installer-owned service definitions were removed."
                        : "One or more service definitions changed outside the installer and were not removed."
                    throw SetupError(
                        "Installation failed and semantic configuration rollback also failed; services were left stopped and this preparing receipt retains the recovery snapshot for an explicit retry. \(definitions) \(error.localizedDescription) \(semanticRollbackError.localizedDescription)"
                    )
                }
                do {
                    try restorePeerConfiguration(receipt, uid: account.uid)
                } catch {
                    let reason = try blockPeerConfigurationRecovery(&receipt)
                    throw SetupError(reason + " " + error.localizedDescription)
                }
                try restoreRegistrationSnapshot(
                    &receipt, previous: previous, release: release, digest: digest,
                    oldDefinition: oldDefinition, oldEmbeddingDefinition: oldEmbeddingDefinition)
                if clientsPublished {
                    do {
                        try setClientRelease(oldClientRelease)
                        try removeTUICommandIfUnused()
                    } catch {
                        try? unload(receipt.instance)
                        try? unloadEmbedding(receipt)
                        var stopped = try readReceipt(receipt.instance) ?? receipt
                        try blockCanonicalRollback(&stopped, error: error)
                        throw SetupError(
                            "Shared client rollback blocked; target services remain stopped and data/backups are retained. "
                                + error.localizedDescription)
                    }
                }
                throw SetupError(
                    "Installation did not become ready; registrations were rolled back and data retained. \((error as? TractandaError)?.description ?? error.localizedDescription)"
                )
            }
        }
    }

    /// Private per-instance state survives runtime switches and uninstall.
    func prepareDocumentState(_ receipt: inout InstallationReceipt, uid: UInt32) throws {
        if receipt.documentExtraction != nil {
            let documents = roots.configuration.appendingPathComponent("document-state")
                .appendingPathComponent(receipt.instance)
            try ensureRootDirectory(documents)
            let scratch = documents.appendingPathComponent("scratch")
            try ensureServiceDirectory(scratch, uid: uid, mode: 0o700)
            receipt.documentScratchDirectory = scratch.path
        }
    }

    /// Restore precisely the previously owned definitions and receipt after candidate startup fails.
    /// Caller stops candidate processes first; client repinning happens only after this guarded restoration.
    func restoreRegistrationSnapshot(
        _ receipt: inout InstallationReceipt, previous: InstallationReceipt?, release: URL, digest: String,
        oldDefinition: Data?, oldEmbeddingDefinition: Data?
    ) throws {
        guard roots.platform == .macos else {
            receipt.state = .preparing
            receipt.recoveryReason =
                "Linux package configuration failed; programs are dpkg-owned. Keep services stopped, retry package configuration or install an older compatible .deb."
            try writeReceipt(receipt)
            throw SetupError(receipt.recoveryReason!)
        }
        if let previous, previous.state == .active { try requireCanonicalReader(previous, quiescent: true) }
        let definition = definitionURL(receipt.instance)
        let embeddingDefinition = embeddingDefinitionURL(receipt.instance)
        if let oldDefinition {
            try writeProtected(oldDefinition, to: definition, mode: 0o644)
        } else if exists(definition) {
            try FileManager.default.removeItem(at: definition)
        }
        if let oldEmbeddingDefinition {
            try writeProtected(oldEmbeddingDefinition, to: embeddingDefinition, mode: 0o644)
        } else if exists(embeddingDefinition) {
            try FileManager.default.removeItem(at: embeddingDefinition)
        }
        if let previous, previous.state == .active {
            var rollback = previous
            rollback.releases[release.path] = digest
            try writeReceipt(rollback)
            do {
                try loadEmbedding(previous)
                try load(previous.instance)
            } catch {
                try? unload(previous.instance)
                try? unloadEmbedding(previous)
                _ = try blockPeerConfigurationRecovery(&rollback)
                throw SetupError(
                    "Previous service could not restart safely; owned boot registrations were disabled. "
                        + error.localizedDescription)
            }
        } else {
            receipt.state = .preparing
            receipt.embeddingDefinitionSHA256 = oldEmbeddingDefinition.map {
                SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
            }
            receipt.definitionSHA256 = oldDefinition.map {
                SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
            }
            try writeReceipt(receipt)
        }
    }

    /// Do not delete a registration that an administrator changed while recovery was in flight.
    /// Returning false leaves the receipt preparing, so ordinary start/restart remains blocked.
    func removeOwnedRegistration(_ url: URL, expectedSHA256: String?) -> Bool {
        guard exists(url) else { return true }
        guard let expectedSHA256, (try? sha256(url)) == expectedSHA256 else { return false }
        do {
            if roots.platform == .linux {
                let owned = try installationReceipts().flatMap { receipt in
                    [
                        (receipt.instance, SetupServiceRole.server),
                        (receipt.instance, SetupServiceRole.embeddings),
                    ]
                }.first { serviceBackend.definitionURL($0.0, role: $0.1) == url }
                guard let (instance, role) = owned else { return false }
                try serviceBackend.disable(instance, role: role)
            }
            try FileManager.default.removeItem(at: url)
            try serviceBackend.reload()
            return !exists(url)
        } catch { return false }
    }

    public func start(_ options: SetupOptions) throws {
        try control(options) { receipt in
            do {
                try verifyPeerConfigurationForLoad(receipt)
                try loadAuthentication(receipt)
                try loadEmbedding(receipt)
                try waitForEmbedding(receipt)
                try load(receipt.instance)
                try waitUntilReady(receipt)
                try verifyPeerConfigurationForLoad(receipt)
            } catch {
                try? unload(receipt.instance)
                try? unloadEmbedding(receipt)
                try? unloadAuthentication(receipt)
                var stopped = receipt
                _ = try blockPeerConfigurationRecovery(&stopped)
                throw error
            }
        }
    }
    public func stop(_ options: SetupOptions) throws {
        try control(options, stopping: true) { receipt in
            try unload(receipt.instance)
            try unloadEmbedding(receipt)
            try unloadAuthentication(receipt)
        }
    }
    public func restart(_ options: SetupOptions) throws {
        try control(options) { receipt in
            try unload(receipt.instance)
            try unloadEmbedding(receipt)
            try unloadAuthentication(receipt)
            do {
                try verifyPeerConfigurationForLoad(receipt)
                try loadAuthentication(receipt)
                try loadEmbedding(receipt)
                try waitForEmbedding(receipt)
                try load(receipt.instance)
                try waitUntilReady(receipt)
                try verifyPeerConfigurationForLoad(receipt)
            } catch {
                try? unload(receipt.instance)
                try? unloadEmbedding(receipt)
                try? unloadAuthentication(receipt)
                var stopped = receipt
                _ = try blockPeerConfigurationRecovery(&stopped)
                throw error
            }
        }
    }
    public func status(_ options: SetupOptions) throws -> String {
        try requireNoPeerConfigurationAction(options)
        try options.validate()
        if roots.platform == .linux {
            try requireLinuxPackageRoot()
            guard let receipt = try readReceipt(options.name) else {
                throw SetupError("There is no owned installation receipt.")
            }
            try verifyRegistration(receipt)
        }
        return try serviceBackend.status(options.name)
    }

    public func uninstall(_ options: SetupOptions) throws {
        guard roots.platform == .macos else {
            throw SetupError(
                "Linux program files belong to dpkg; use package removal, which preserves canonical data.")
        }
        try requireNoPeerConfigurationAction(options)
        try requireRootAndPlatform()
        try options.validate()
        try withInstallerLock {
            guard var receipt = try readReceipt(options.name) else {
                throw SetupError("There is no owned installation receipt.")
            }
            try verifyRegistration(receipt)
            _ = try currentClientRelease()
            // Verify everything to be removed before unloading any running process.
            for (path, digest) in receipt.releases where exists(URL(fileURLWithPath: path)) {
                let url = URL(fileURLWithPath: path)
                guard
                    url.deletingLastPathComponent()
                        == roots.software.appendingPathComponent("releases"),
                    try sha256(url.appendingPathComponent("bundle-manifest.json")) == digest
                else {
                    throw SetupError("An installed release differs from its receipt; nothing was removed.")
                }
                _ = try verifyBundle(at: url)
            }
            let account = try SystemAccountDirectory().user(named: roots.platform.serviceUser)
            guard receipt.peerRuntimePrevious == nil else {
                throw SetupError("Finish peer configuration recovery before uninstall.")
            }
            let peerBytes = try ownedPeerBytes(
                receipt.peerRuntimeConfiguration, instance: receipt.instance, uid: account.uid)
            try unload(receipt.instance)
            try unloadEmbedding(receipt)
            try publishPeerBytes(nil, replacing: peerBytes, instance: receipt.instance, uid: account.uid)
            receipt.peerRuntimeConfiguration = nil
            let definition = definitionURL(receipt.instance)
            if exists(definition) { try FileManager.default.removeItem(at: definition) }
            if receipt.embedding != nil && exists(embeddingDefinitionURL(receipt.instance)) {
                try FileManager.default.removeItem(at: embeddingDefinitionURL(receipt.instance))
            }
            try removeGlobalProfile(receipt)
            try removeClientLink(receipt)
            try removeTUICommandIfUnused()
            receipt.state = .removed
            receipt.definitionSHA256 = nil
            receipt.embeddingDefinitionSHA256 = nil
            try writeReceipt(receipt)
            let retained = try releasesUsedByOtherInstances(receipt.instance)
            for path in receipt.releases.keys
            where !retained.contains(path) && exists(URL(fileURLWithPath: path)) {
                try FileManager.default.removeItem(atPath: path)
            }
            // Retain the receipt with canonical data location/ownership for a later reinstall.
            // No account, home directory, canonical record or index is removed.
        }
    }

    func control(
        _ options: SetupOptions, stopping: Bool = false, action: (InstallationReceipt) throws -> Void
    ) throws {
        if roots.platform == .linux { try requireLinuxPackageRoot() } else { try requireRootAndPlatform() }
        try options.validate()
        try requireNoPeerConfigurationAction(options)
        try withInstallerLock {
            guard let receipt = try readReceipt(options.name),
                receipt.state == .active || stopping && roots.platform == .linux
            else {
                throw SetupError("This instance is not fully installed.")
            }
            try verifyRegistration(receipt)
            if roots.platform == .linux, !stopping {
                try requireNoPendingPackageMutation()
                try packageRuntimeGuard(options.name)
            }
            try action(receipt)
        }
    }

    func validateRoots(data: URL? = nil, indexes: URL? = nil) throws {
        let data = data ?? roots.data
        let indexes = indexes ?? roots.indexes
        let paths = [data, indexes, roots.software, roots.configuration, roots.runtime]
        guard paths.allSatisfy({ $0.path.hasPrefix("/") && $0.path != "/" && !$0.path.contains("\0") }) else {
            throw SetupError("Installer roots must be absolute non-root directories.")
        }
        func overlaps(_ first: URL, _ second: URL) -> Bool {
            let a = first.standardizedFileURL.path
            let b = second.standardizedFileURL.path
            return a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
        }
        let reserved = [
            roots.software.appendingPathComponent("releases"), clientLink,
            roots.configuration.appendingPathComponent("receipts"),
            roots.configuration.appendingPathComponent("logs"),
            roots.configuration.appendingPathComponent("document-state"),
            roots.configuration.appendingPathComponent("connections.json"),
            roots.configuration.appendingPathComponent("installer.lock"), roots.runtime,
        ]
        guard !overlaps(data, indexes),
            !reserved.contains(where: {
                overlaps(data, $0) || overlaps(indexes, $0)
            })
        else {
            throw SetupError(
                "Canonical data and indexes must be separate from each other and the installed software/runtime."
            )
        }
    }

    func requireRootAndPlatform() throws {
        guard rootCheck() else { throw SetupError("Run the installer through sudo.") }
        guard roots.platform == .macos else {
            throw SetupError(
                "Linux package lifecycle integration is not yet available; Setup must not mutate dpkg-owned programs."
            )
        }
    }
    func resolvedOwner(_ options: SetupOptions) throws -> String {
        guard let owner = options.owner ?? ProcessInfo.processInfo.environment["SUDO_USER"] else {
            throw SetupError("Specify --owner or run through sudo.")
        }
        let identity = try SystemAccountDirectory().user(named: owner)
        guard identity.uid != 0 else {
            throw SetupError("Choose an existing human OS account as the initial owner.")
        }
        return identity.name
    }
    func requirePackageRelease(_ release: String) throws {
        if roots.platform == .linux {
            let active = roots.software.appendingPathComponent("current")
            guard release == active.path, !isLink(active) else {
                throw SetupError(
                    "Linux installation receipts must identify the fixed dpkg-owned active program directory."
                )
            }
        }
    }
    func releaseURL(_ options: SetupOptions, manifest: BundleManifest, digest: String) -> URL {
        if roots.platform == .linux { return roots.software.appendingPathComponent("current") }
        return roots.software.appendingPathComponent("releases")
            .appendingPathComponent(manifest.version + "-" + digest.prefix(12))
    }
    func definitionURL(_ name: String) -> URL {
        serviceBackend.definitionURL(name)
    }
    func label(_ name: String) -> String { serviceBackend.label(name) }
    func receiptURL(_ name: String) -> URL {
        roots.configuration.appendingPathComponent("receipts/" + name + ".json")
    }
    func successful(_ executable: String, _ arguments: [String], startup: Bool = false) throws {
        let result =
            try startup
            ? runner.runStartup(executable, arguments, environment: [:])
            : runner.run(executable, arguments, environment: [:])
        guard result.status == 0 else {
            throw SetupError("Command failed: \(executable): \(result.output.prefix(4096))")
        }
    }
    func load(_ name: String) throws {
        guard let receipt = try readReceipt(name) else {
            throw SetupError("Owned registration proof is missing.")
        }
        try verifyPeerConfigurationForLoad(receipt)
        if roots.platform == .linux {
            // A verified owned publication may be newer than the manager's loaded definition.
            // Refresh before asking isRunning to reject foreign/stale effective state.
            try verifyRegistration(receipt)
            try serviceBackend.reload()
        }
        if try !serviceBackend.isRunning(name) {
            try requireCanonicalReader(receipt, quiescent: true)
        }
        try serviceBackend.load(name, enableAtBoot: !(try packageStartupIsConfiguring(name)))
    }
    func unload(_ name: String) throws {
        try serviceBackend.unload(name)
    }
    func replaceRegistration(_ receipt: inout InstallationReceipt) throws {
        let bytes = try serviceDefinition(receipt)
        try unload(receipt.instance)
        try requireCanonicalReader(receipt, quiescent: true)
        if roots.platform == .linux {
            try publishPackageDefinition(bytes, role: .server, receipt: &receipt)
        } else {
            try writeProtected(bytes, to: definitionURL(receipt.instance), mode: 0o644)
        }
        receipt.definitionSHA256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try writeReceipt(receipt)
        try load(receipt.instance)
    }
    func serviceDefinition(_ receipt: InstallationReceipt) throws -> Data {
        try requirePackageRelease(receipt.release)
        var arguments = [
            URL(fileURLWithPath: receipt.release).appendingPathComponent("bin/tractanda").path,
            "daemon", receipt.store, receipt.socket, "--index-directory", receipt.indexDirectory,
            "--managed", "--http-port", String(receipt.port),
        ]
        if let peer = receipt.peerRuntimeConfiguration {
            arguments += ["--peer-runtime-config", peer.path]
        }
        if let document = receipt.documentExtraction {
            guard document == .pinned else { throw SetupError("Unsupported document receipt.") }
            let scratch = try documentStatePaths(receipt)
            let release = URL(fileURLWithPath: receipt.release)
            arguments += [
                "--document-converter", release.appendingPathComponent(document.converterPath).path,
                "--document-model-directory", release.appendingPathComponent(document.modelDirectory).path,
                "--document-scratch-directory", scratch,
            ]
        }
        if let project = receipt.board["projectID"], let projects = receipt.board["projectRootID"],
            let status = receipt.board["statusRootID"]
        {
            arguments += ["--project-root", projects, "--status-root", status, "--project", project]
        }
        if roots.platform == .linux {
            var environment: [String: String] = [:]
            if let node = receipt.uuidNode { environment["TRACTANDA_UUID_NODE"] = node }
            environment["TRACTANDA_AUTH_SOCKET"] = "/run/tractanda-auth-" + receipt.instance + "/auth.sock"
            return try serviceBackend.systemdDefinition(
                instance: receipt.instance, role: .server,
                arguments: arguments, environment: environment)
        }
        var dictionary: [String: Any] = [
            "Label": "ai.tractanda.server." + receipt.instance, "ProgramArguments": arguments,
            "UserName": roots.platform.serviceUser, "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false], "ThrottleInterval": 5, "Umask": 0o077,
            "StandardOutPath": roots.configuration.appendingPathComponent("logs/" + receipt.instance + ".log")
                .path,
            "StandardErrorPath": roots.configuration.appendingPathComponent(
                "logs/" + receipt.instance + ".log"
            ).path,
        ]
        if let node = receipt.uuidNode { dictionary["EnvironmentVariables"] = ["TRACTANDA_UUID_NODE": node] }
        return try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
    }
    func documentStatePaths(_ receipt: InstallationReceipt) throws -> String {
        let root = roots.configuration.appendingPathComponent("document-state").appendingPathComponent(
            receipt.instance)
        let scratch = root.appendingPathComponent("scratch").path
        guard receipt.documentScratchDirectory == scratch
        else { throw SetupError("Document workspace differs from the owned instance paths.") }
        return scratch
    }

    /// Configuration readiness only; successful inference is a separate validation gate.
    func verifyDocumentReadiness(_ receipt: InstallationReceipt, info: [String: Any]) throws {
        let extraction = info["documentExtraction"] as? [String: Any]
        guard let document = receipt.documentExtraction else {
            guard extraction?["state"] as? String == "unavailable" else {
                throw SetupError("Unexpected document configuration in the running service.")
            }
            return
        }
        let release = URL(fileURLWithPath: receipt.release)
        guard let identityObject = extraction?["identity"] as? [String: Any] else {
            throw SetupError("Running document identity is unavailable.")
        }
        let identityBytes = try JSONSerialization.data(withJSONObject: identityObject)
        let identity = try JSONDecoder().decode(DocumentConverterIdentity.self, from: identityBytes)
        guard extraction?["state"] as? String == "configured", identity == document.identity,
            extraction?["executableSHA256"] as? String
                == (try sha256(release.appendingPathComponent(document.converterPath))),
            extraction?["requiresPreparedInput"] as? Bool == false,
            (info["documentJobs"] as? [String: Any])?["protocol"] as? String == document.workerProtocol
        else { throw SetupError("Running document configuration differs from the owned release.") }
    }

    func waitUntilReady(_ receipt: InstallationReceipt) throws {
        if let document = receipt.documentExtraction {
            guard document == .pinned else { throw SetupError("Unsupported document receipt.") }
            _ = try documentStatePaths(receipt)
        }
        if let readinessCheck {
            try readinessCheck(receipt.socket, roots.platform.serviceUser, receipt.port)
            try verifyPeerReadiness(
                receipt, status: peerStatusCall(receipt.socket, roots.platform.serviceUser))
            return
        }
        try SetupStartupWait.run(
            observe: {
                try self.serviceBackend.startupObservation(receipt.instance)
            },
            probe: {
                let info = try SetupNativeClient(
                    socket: receipt.socket, serverUser: roots.platform.serviceUser
                ).call("TractandaStore/info")
                let uid = try SystemAccountDirectory().user(named: roots.platform.serviceUser).uid
                guard info["ownerUID"] as? UInt32 == uid, info["accessMode"] as? String == "multi-user",
                    info["callerIsAdministrator"] as? Bool == true
                else {
                    throw SetupError("Service identity or admission policy differs from the installation.")
                }
                try verifyCanonicalReadiness(receipt, info: info)
                try verifySelectedReplicaIdentity(receipt)
                try verifyDocumentReadiness(receipt, info: info)
                try verifyPeerReadiness(
                    receipt, status: peerStatusCall(receipt.socket, roots.platform.serviceUser))
                let http = try runner.run(
                    "/usr/bin/curl",
                    [
                        "--noproxy", "*", "--fail", "--silent", "--show-error", "--max-time", "2",
                        "http://127.0.0.1:\(receipt.port)/manual",
                    ], environment: [:])
                guard http.status == 0, http.output.contains("Tractanda") else {
                    throw SetupError("The HTTP listener is not ready.")
                }
                return
            })
    }
}
