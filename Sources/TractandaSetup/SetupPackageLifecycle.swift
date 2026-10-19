import Crypto
import Foundation
import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

extension SetupEngine {
    /// All commands are finite. Kernel installer/writer locks end on return; protected pending
    /// state and the fixed runtime guard cover the intervals between dpkg hooks.
    func packageLifecycle(_ arguments: SetupPackageArguments) throws -> String {
        try requireLinuxPackageRoot()
        if arguments.action == .runtimeGuard {
            guard let instance = arguments.instance else {
                throw SetupError("Missing package runtime instance.")
            }
            try packageRuntimeGuard(instance)
            return "Managed package startup admitted."
        }
        let incoming = try arguments.descriptor.map(capturePackageDescriptor)
        try ensureRootDirectory(roots.configuration)
        return try withInstallerLockResult {
            try recoverPackageDefinitions()
            switch arguments.action {
            case .prermUpgrade:
                _ = try preparePackageUpgrade(incoming: nil)
                return "All owned configured instances quiesced; original service intent retained."
            case .preinst:
                guard let incoming else { throw SetupError("Missing incoming package declaration.") }
                _ = try preparePackageUpgrade(incoming: incoming)
                return "Incoming package declaration admitted; managed startup remains blocked during unpack."
            case .configure:
                guard let incoming else { throw SetupError("Missing configured package declaration.") }
                return try configurePackage(incoming)
            case .abortUpgrade:
                try abortPackageUpgrade()
                return "Package operation aborted; services remain stopped pending verified package recovery."
            case .remove:
                try removePackageRegistration()
                return "Package services deconfigured; canonical/private state and service intent retained."
            case .runtimeGuard:
                throw SetupError("Runtime guard cannot mutate package state.")
            }
        }
    }

    func withInstallerLockResult<T>(_ body: () throws -> T) throws -> T {
        var value: T?
        try withInstallerLock { value = try body() }
        guard let value else { throw SetupError("Installer transaction produced no result.") }
        return value
    }

    func packageDefinitionHash(_ receipt: InstallationReceipt, role: SetupServiceRole) -> String? {
        switch role {
        case .server: receipt.definitionSHA256
        case .embeddings: receipt.embeddingDefinitionSHA256
        case .authentication: receipt.authenticationDefinitionSHA256
        }
    }

    func verifyPackageDefinitionFiles(_ receipts: [InstallationReceipt]) throws {
        let expected = Set(
            receipts.flatMap { receipt in
                [SetupServiceRole.server, .embeddings, .authentication].map {
                    serviceBackend.name(receipt.instance, role: $0)
                }
            })
        for arguments in [
            [
                "list-units", "--all", "--no-legend", "--plain", "--full", "--type=service",
                "tractanda-*.service",
            ],
            ["list-unit-files", "--no-legend", "--no-pager", "tractanda-*.service"],
        ] {
            let result = try runner.run("/usr/bin/systemctl", arguments, environment: [:])
            // systemd 257 reports an exact empty unit-file inventory with exit one.
            let emptyUnitFiles =
                arguments == ["list-unit-files", "--no-legend", "--no-pager", "tractanda-*.service"]
                && result.status == 1 && result.output.isEmpty
            guard result.status == 0 || emptyUnitFiles, result.output.utf8.count <= 262_144 else {
                throw SetupError("Cannot establish bounded managed service inventory.")
            }
            var names = Set<String>()
            for line in result.output.split(separator: "\n") {
                guard let name = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first,
                    expected.contains(String(name)), names.insert(String(name)).inserted
                else {
                    throw SetupError("Unowned or ambiguous managed system service blocks package handoff.")
                }
            }
        }
        if exists(roots.launchDefinitions) {
            try requireOwned(roots.launchDefinitions, uid: 0, directory: true)
            let entries = try FileManager.default.contentsOfDirectory(atPath: roots.launchDefinitions.path)
            for name in entries where name.hasPrefix("tractanda-") {
                let unit = name.hasSuffix(".d") ? String(name.dropLast(2)) : name
                guard expected.contains(unit) else {
                    throw SetupError("Unowned managed definition or override blocks package handoff.")
                }
            }
        }
        for receipt in receipts {
            try verifyRegistration(receipt)
            for role in [SetupServiceRole.server, .embeddings, .authentication] {
                let url = serviceBackend.definitionURL(receipt.instance, role: role)
                if let hash = packageDefinitionHash(receipt, role: role) {
                    guard exists(url) else {
                        throw SetupError("Owned package service definition is missing: " + receipt.instance)
                    }
                    try requireOwned(url, uid: 0, directory: false)
                    guard try sha256(url) == hash else {
                        throw SetupError("Package service definition drift blocks the transaction.")
                    }
                } else if exists(url) {
                    throw SetupError("Unowned package service definition blocks the transaction.")
                }
            }
        }
    }

    func packageServiceState(_ receipt: InstallationReceipt, role: SetupServiceRole) throws
        -> SetupSystemdState?
    {
        let state = try serviceBackend.systemdState(receipt.instance, role: role)
        guard packageDefinitionHash(receipt, role: role) != nil else {
            guard state.loadState == "not-found", state.mainPID == 0,
                state.activeState == "inactive", state.fragmentPath.isEmpty, state.dropInPaths.isEmpty
            else {
                throw SetupError("A loaded package service has no owned definition.")
            }
            return nil
        }
        try state.requireOwned(fragment: serviceBackend.definitionURL(receipt.instance, role: role))
        guard !["activating", "deactivating"].contains(state.activeState) else {
            throw SetupError("Package service is still changing state.")
        }
        return state
    }

    func packageStopServices(_ receipts: [InstallationReceipt]) throws {
        var failures: [String] = []
        for receipt in receipts {
            for role in [SetupServiceRole.server, .embeddings, .authentication] {
                guard packageDefinitionHash(receipt, role: role) != nil else { continue }
                do { try serviceBackend.disable(receipt.instance, role: role) } catch {
                    failures.append(
                        receipt.instance + "/" + role.rawValue + ": " + error.localizedDescription)
                }
            }
        }
        guard failures.isEmpty else {
            throw SetupError(
                "Package quiescence is incomplete; no overwrite is admitted. "
                    + failures.joined(separator: "; ").prefix(3000))
        }
    }

    func preparePackageUpgrade(incoming: SetupPackageCompatibility?) throws -> SetupPackageState {
        let prior = try readPackageState()
        if let owner = prior?.owner, packageOwnerIsLive(owner) {
            throw SetupError("Another live configure operation owns this package transaction.")
        }
        let receipts = try installationReceipts()
        try verifyPackageDefinitionFiles(receipts)
        try serviceBackend.reload()
        // Repeated hooks must inspect all roles too, including a loaded role lacking a receipt
        // hash. Pending state is not permission to skip effective manager custody.
        for receipt in receipts {
            for role in [SetupServiceRole.server, .embeddings, .authentication] {
                _ = try packageServiceState(receipt, role: role)
            }
        }
        let installed = try installedPackageCompatibility()
        var state: SetupPackageState
        if let prior, prior.pending || prior.phase == .removed {
            guard Set(prior.instances.map(\.name)) == Set(receipts.map(\.instance)) else {
                throw SetupError("Owned instance inventory changed during a pending package transaction.")
            }
            let commitments = [
                prior.original?.manifestSHA256, prior.incoming?.manifestSHA256,
                prior.observed?.manifestSHA256,
            ].compactMap {
                $0
            }
            guard commitments.contains(installed.manifestSHA256) else {
                throw SetupError("Actual package payload is outside the retained transaction commitments.")
            }
            state = prior  // Never recapture stopped/preparing state as the original service intent.
        } else {
            var instances: [SetupPackageState.Instance] = []
            for receipt in receipts {
                guard receipt.initialized, !receipt.sample || receipt.sampled else {
                    throw SetupError(
                        "Finish explicit owned store initialization before changing the installed package.")
                }
                let server = try packageServiceState(receipt, role: .server)
                let embedding = try packageServiceState(receipt, role: .embeddings)
                let authentication = try packageServiceState(receipt, role: .authentication)
                let support = [authentication, embedding].compactMap { $0 }
                guard
                    support.allSatisfy({
                        $0.running == (server?.running == true)
                            && ($0.unitFileState == "enabled") == (server?.unitFileState == "enabled")
                    })
                else {
                    throw SetupError(
                        "Support services have different running/boot intent; resolve that state before an ordinary package upgrade."
                    )
                }
                instances.append(
                    .init(
                        name: receipt.instance, originalManifestSHA256: receipt.manifestSHA256,
                        wasRunning: server?.running == true, wasEnabled: server?.unitFileState == "enabled",
                        embeddingWasRunning: embedding?.running == true,
                        authenticationWasRunning: authentication?.running == true))
            }
            state = try SetupPackageState(original: installed, instances: instances)
        }
        state.owner = nil
        state.observed = installed
        state.startupPermitted = []
        state.phase = .quiescing
        state.recoveryReason = nil
        if let incoming { state.incoming = incoming }
        try writePackageState(state)  // Deny managed starts before stopping even the first instance.
        do {
            try packageStopServices(receipts)
            if let incoming, let original = state.original {
                try incoming.requireRollingUpgrade(from: original)
            }
            for receipt in receipts {
                let requirement = try quiescentCanonicalRequirement(receipt)
                if let incoming { try incoming.canonicalFormats.require(requirement) }
            }
            state.phase = incoming == nil ? .quiesced : .awaitingUnpack
            try writePackageState(state)
            return state
        } catch {
            state.phase = .failed
            state.recoveryReason = boundedPackageReason(
                "Package pre-unpack failed; services already stopped remain stopped and no payload replacement is admitted. "
                    + error.localizedDescription)
            try writePackageState(state)
            throw error
        }
    }

    func abortPackageUpgrade() throws {
        guard var state = try readPackageState(), state.pending else { return }
        if let owner = state.owner, packageOwnerIsLive(owner) {
            throw SetupError("A live configure operation cannot be superseded by an abort hook.")
        }
        let receipts = try installationReceipts()
        state.phase = .failed
        state.owner = nil
        state.startupPermitted = []
        state.recoveryReason =
            "Package operation aborted. No previous program bytes were restored; reinstall a verified compatible package or finish configuration."
        try writePackageState(state)
        try verifyPackageDefinitionFiles(receipts)
        try serviceBackend.reload()
        try packageStopServices(receipts)
    }

    func removePackageRegistration() throws {
        var state = try preparePackageUpgrade(incoming: nil)
        let receipts = try installationReceipts()
        do {
            for var receipt in receipts {
                receipt.state = .preparing
                for role in [SetupServiceRole.server, .embeddings, .authentication] {
                    try publishPackageDefinition(nil, role: role, receipt: &receipt)
                }
                receipt.definitionSHA256 = nil
                receipt.embeddingDefinitionSHA256 = nil
                receipt.authenticationDefinitionSHA256 = nil
                receipt.state = receipt.peerRuntimePrevious == nil ? .removed : .preparing
                receipt.recoveryReason =
                    "Package removed; canonical data, private configuration and recovery state are retained."
                try writeReceipt(receipt)
            }
            try serviceBackend.reload()
            state.phase = .removed
            state.owner = nil
            state.startupPermitted = []
            state.recoveryReason =
                "Package delivery removed; all retained canonical/private state is preserved."
            try writePackageState(state)
        } catch {
            state.phase = .failed
            state.recoveryReason = boundedPackageReason(
                "Package removal needs recovery; no canonical/private data was deleted. "
                    + error.localizedDescription)
            try writePackageState(state)
            throw error
        }
    }
}

extension SetupEngine {
    /// Only the finite package coordinator calls this internal path while it owns installer.lock.
    func withPackageInstallerLock(_ operationID: String?, _ body: () throws -> Void) throws {
        guard let operationID else {
            try withInstallerLock {
                try requireNoPendingPackageMutation()
                if roots.platform == .linux { try recoverPackageDefinitions() }
                try body()
            }
            return
        }
        guard let state = try readPackageState(), state.operationID == operationID,
            state.phase == .configuring,
            let owner = state.owner, owner.pid == getpid(), packageOwnerIsLive(owner)
        else {
            throw SetupError("The live package coordinator does not own this instance configuration.")
        }
        try body()
    }
}

extension SetupEngine {
    func configurePackage(_ incoming: SetupPackageCompatibility) throws -> String {
        let manifest = try verifyBundle(at: packagePayload)
        let digest = try sha256(packagePayload.appendingPathComponent("bundle-manifest.json"))
        try incoming.requirePayload(manifest, digest: digest)
        _ = try installedPackageCompatibility()  // Includes complete production component boundary.
        let existing = try readPackageState()
        let receipts = try installationReceipts()
        if existing == nil {
            guard receipts.isEmpty else {
                throw SetupError(
                    "Existing instance receipts lack a package transaction; explicit recovery is required.")
            }
            try verifyPackageDefinitionFiles(receipts)
            var state = try SetupPackageState(original: nil, instances: [])
            state.incoming = incoming
            state.observed = incoming
            state.phase = .committed
            try writePackageState(state)
            return
                "Package payload configured; no instance was initialized, enrolled or started. Select standalone initialization or prepared-target adoption explicitly."
        }
        if let existing, existing.phase == .committed, existing.incoming == incoming {
            try verifyPackageDefinitionFiles(receipts)
            guard receipts.allSatisfy({ $0.manifestSHA256 == incoming.manifestSHA256 }) else {
                throw SetupError("Committed package receipts differ from the actual active payload.")
            }
            return "Package configuration already committed; service intent is unchanged."
        }
        var state = try preparePackageUpgrade(incoming: incoming)
        // Preparation after unpack deliberately preserves the original pre-upgrade intent.
        state.phase = .configuring
        state.owner = try packageOwnerIdentity()
        state.startupPermitted = []
        try writePackageState(state)
        var started = 0
        var stoppedByIntent = 0
        var stoppedByPolicy = 0
        do {
            for intent in state.instances {
                guard var receipt = try readReceipt(intent.name), receipt.initialized,
                    !receipt.sample || receipt.sampled
                else {
                    throw SetupError(
                        "Package configure cannot initialize or seed a store; finish the explicit setup operation."
                    )
                }
                try incoming.canonicalFormats.require(quiescentCanonicalRequirement(receipt))
                var allowStart = intent.wasRunning
                if intent.wasRunning {
                    let requiredRoles: [SetupServiceRole] =
                        receipt.embedding == nil
                        ? [.server, .authentication] : [.server, .authentication, .embeddings]
                    for role in requiredRoles {
                        let permission = try packagePolicyAllowsStart(intent.name, role: role)
                        allowStart = allowStart && permission
                    }
                }
                if intent.wasRunning && allowStart {
                    state.startupPermitted = Array(Set(state.startupPermitted + [intent.name])).sorted()
                    try writePackageState(state)
                    let options = SetupOptions(
                        name: receipt.instance, owner: receipt.owner,
                        mode: receipt.sample ? .sample : .empty, port: receipt.port,
                        bundle: packagePayload, uuidNode: receipt.uuidNode, peerRuntime: .preserve)
                    try installForPackage(options, operationID: state.operationID)
                    started += 1
                } else {
                    try configureStoppedPackageInstance(&receipt, manifest: manifest, incoming: incoming)
                    if intent.wasRunning { stoppedByPolicy += 1 } else { stoppedByIntent += 1 }
                }
            }
            // Keep phase configuring and its live-owner guard through boot publication. If the
            // owner dies halfway, stale permits deny subsequent boot/restart, even if a link exists.
            for intent in state.instances where intent.wasEnabled {
                guard let receipt = try readReceipt(intent.name), receipt.state == .active else { continue }
                for role in [SetupServiceRole.authentication, .embeddings, .server]
                where packageDefinitionHash(receipt, role: role) != nil {
                    try serviceBackend.enable(intent.name, role: role)
                }
            }
            state.phase = .committed
            state.owner = nil
            state.startupPermitted = []
            state.recoveryReason =
                stoppedByPolicy > 0
                ? "Configured with " + String(stoppedByPolicy)
                    + " instance(s) stopped by service-start policy; runtime readiness was not claimed for them."
                : nil
            try writePackageState(state)
            return "Package configured: " + String(started) + " verified restart(s), "
                + String(stoppedByIntent)
                + " intentionally stopped, " + String(stoppedByPolicy)
                + " stopped by policy. No new store was initialized."
        } catch {
            state.phase = .failed
            state.owner = nil
            state.startupPermitted = []
            state.recoveryReason = boundedPackageReason(
                "Package configure failed against the actual installed payload; no previous program was restored. "
                    + error.localizedDescription)
            try writePackageState(state)  // Deny new managed starts before best-effort stop/disable.
            do {
                try recoverPackageDefinitions()
                let actual = try installationReceipts()
                try verifyPackageDefinitionFiles(actual)
                try serviceBackend.reload()
                try packageStopServices(actual)
            } catch {
                state.recoveryReason = boundedPackageReason(
                    (state.recoveryReason ?? "Package configure failed.")
                        + " Some unit cleanup could not be proved and needs administrator recovery: "
                        + error.localizedDescription)
                try writePackageState(state)
                throw SetupError(state.recoveryReason!)
            }
            throw SetupError(state.recoveryReason!)
        }
    }

    func packagePolicyAllowsStart(_ instance: String, role: SetupServiceRole = .server) throws -> Bool {
        let unit = serviceBackend.name(instance, role: role)
        if let packageStartPolicy { return try packageStartPolicy(unit) }
        let policy = "/usr/sbin/policy-rc.d"
        guard FileManager.default.isExecutableFile(atPath: policy) else { return true }
        let result = try runner.run(policy, [unit, "start"], environment: [:])
        switch result.status {
        case 0, 104: return true
        case 101: return false
        default:
            throw SetupError("Service-start policy did not provide an unambiguous permitted/denied result.")
        }
    }

    func configureStoppedPackageInstance(
        _ receipt: inout InstallationReceipt,
        manifest: BundleManifest, incoming: SetupPackageCompatibility
    ) throws {
        guard receipt.embedding == manifest.embedding,
            receipt.documentExtraction == manifest.documentExtraction
        else {
            throw SetupError("A package cannot silently change or remove the configured bundled components.")
        }
        try verifyRegistration(receipt)
        try verifyPeerConfigurationForLoad(receipt)
        receipt.release = packagePayload.path
        receipt.manifestSHA256 = incoming.manifestSHA256
        receipt.releases = [packagePayload.path: incoming.manifestSHA256]
        receipt.state = .preparing
        try writeReceipt(receipt)
        let server = try serviceDefinition(receipt)
        try publishPackageDefinition(server, role: .server, receipt: &receipt)
        receipt.definitionSHA256 = SHA256.hash(data: server).map { String(format: "%02x", $0) }.joined()
        let authentication = try serviceBackend.authenticationDefinition(instance: receipt.instance)
        try publishPackageDefinition(authentication, role: .authentication, receipt: &receipt)
        receipt.authenticationDefinitionSHA256 = SHA256.hash(data: authentication).map {
            String(format: "%02x", $0)
        }.joined()
        if let payload = receipt.embedding {
            let argv = [
                packagePayload.appendingPathComponent("bin/tractanda-embeddings").path,
                "--model", packagePayload.appendingPathComponent(payload.modelDirectory).path,
                "--port", String(receipt.port + 1),
            ]
            let bytes = try serviceBackend.systemdDefinition(
                instance: receipt.instance, role: .embeddings, arguments: argv)
            try publishPackageDefinition(bytes, role: .embeddings, receipt: &receipt)
            receipt.embeddingDefinitionSHA256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }
                .joined()
        }
        receipt.state = receipt.peerRuntimePrevious == nil ? .active : .preparing
        receipt.recoveryReason =
            receipt.peerRuntimePrevious == nil
            ? "Package configured without starting this previously stopped or policy-blocked instance."
            : "Private configuration recovery remains pending; package configuration did not invent replacement bytes."
        try writeReceipt(receipt)
        try serviceBackend.reload()
    }

    func setPackageDefinitionHash(_ hash: String?, role: SetupServiceRole, receipt: inout InstallationReceipt)
    {
        switch role {
        case .server: receipt.definitionSHA256 = hash
        case .embeddings: receipt.embeddingDefinitionSHA256 = hash
        case .authentication: receipt.authenticationDefinitionSHA256 = hash
        }
    }

    /// The small old/desired witness precedes the only mutable file operation. A crash after
    /// publication but before its final receipt can therefore be distinguished from foreign bytes.
    func publishPackageDefinition(
        _ bytes: Data?, role: SetupServiceRole, receipt: inout InstallationReceipt
    ) throws {
        let path = serviceBackend.definitionURL(receipt.instance, role: role)
        let old = packageDefinitionHash(receipt, role: role)
        let desired = bytes.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        guard receipt.packageDefinitions?[role.rawValue] == nil else {
            throw SetupError("Pending owned definition publication must be recovered first.")
        }
        let actual: String?
        if exists(path) {
            try requireOwned(path, uid: 0, directory: false)
            actual = try sha256(path)
        } else {
            actual = nil
        }
        guard actual == old else { throw SetupError("Package definition differs before publication.") }
        guard old != desired else { return }
        receipt.state = .preparing
        receipt.packageDefinitions = receipt.packageDefinitions ?? [:]
        receipt.packageDefinitions![role.rawValue] = .init(old: old, desired: desired)
        try writeReceipt(receipt)
        if let bytes {
            try writeProtected(bytes, to: path, mode: 0o644)
        } else {
            try FileManager.default.removeItem(at: path)
        }
        try packageDefinitionMutation?(receipt.instance, role, bytes == nil)
        setPackageDefinitionHash(desired, role: role, receipt: &receipt)
        receipt.packageDefinitions?.removeValue(forKey: role.rawValue)
        if receipt.packageDefinitions?.isEmpty == true { receipt.packageDefinitions = nil }
        try writeReceipt(receipt)
    }

    /// Only package/explicit-setup recovery under installer.lock uses these receipt witnesses.
    /// No bytes outside each exact old/desired pair, or unintended absence, are admitted.
    func recoverPackageDefinitions() throws {
        let pending = try installationReceipts().filter { !($0.packageDefinitions ?? [:]).isEmpty }
        guard !pending.isEmpty else { return }
        guard let state = try readPackageState(), state.owner.map(packageOwnerIsLive) != true else {
            throw SetupError("A live or unknown package operation blocks definition recovery.")
        }
        let installed = try installedPackageCompatibility()
        guard
            [state.original?.manifestSHA256, state.incoming?.manifestSHA256, state.observed?.manifestSHA256]
                .compactMap({ $0 }).contains(installed.manifestSHA256)
        else {
            throw SetupError("Definition recovery cannot identify the actual installed payload.")
        }
        var recovered: [(InstallationReceipt, [SetupServiceRole])] = []
        for var receipt in pending {
            guard receipt.state == .preparing,
                receipt.packageSetupOwner.map(packageOwnerIsLive) != true
            else {
                throw SetupError("Definition recovery lacks stopped/pending installation custody.")
            }
            if state.pending || state.phase == .removed {
                guard state.instances.contains(where: { $0.name == receipt.instance }) else {
                    throw SetupError("Pending definition is outside the captured instance inventory.")
                }
            }
            var roles: [SetupServiceRole] = []
            for role in [SetupServiceRole.server, .embeddings, .authentication] {
                guard let change = receipt.packageDefinitions?[role.rawValue] else { continue }
                guard packageDefinitionHash(receipt, role: role) == change.old else {
                    throw SetupError("Pending definition's old hash differs from its receipt.")
                }
                let path = serviceBackend.definitionURL(receipt.instance, role: role)
                let actual: String?
                if exists(path) {
                    try requireOwned(path, uid: 0, directory: false)
                    actual = try sha256(path)
                } else {
                    actual = nil
                }
                guard actual == change.old || actual == change.desired else {
                    throw SetupError("Foreign bytes or unintended absence block definition recovery.")
                }
                setPackageDefinitionHash(actual, role: role, receipt: &receipt)
                roles.append(role)
            }
            try verifyRegistration(receipt)
            recovered.append((receipt, roles))
        }
        try serviceBackend.reload()
        for (var receipt, roles) in recovered {
            for role in roles {
                if packageDefinitionHash(receipt, role: role) != nil {
                    try serviceBackend.disable(receipt.instance, role: role)
                } else {
                    let actual = try serviceBackend.systemdState(receipt.instance, role: role)
                    guard actual.loadState == "not-found", actual.activeState == "inactive",
                        actual.mainPID == 0, actual.fragmentPath.isEmpty, actual.dropInPaths.isEmpty,
                        !actual.needsReload, ["disabled", "not-found", ""].contains(actual.unitFileState)
                    else {
                        throw SetupError("Removed definition still has unproved manager/startup state.")
                    }
                }
            }
            receipt.packageDefinitions = nil
            try writeReceipt(receipt)
        }
    }

    func boundedPackageReason(_ value: String) -> String {
        var bytes = Array(value.utf8.prefix(4096))
        while String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self)
    }
}
