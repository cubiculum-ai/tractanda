import CTractandaPlatform
import Crypto
import Foundation
import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

extension SetupEngine {
    func requireLinuxPackageRoot() throws {
        guard roots.platform == .linux, rootCheck() else {
            throw SetupError("Linux package lifecycle requires root custody.")
        }
        let account = try SystemAccountDirectory().user(named: roots.platform.serviceUser)
        guard account.uid != 0 else { throw SetupError("The existing daemon account must be unprivileged.") }
        try validateRoots()
        if trustedOwnership { try requireTrustedAncestry(of: roots.configuration) }
    }

    /// Runs as root from the fixed system-unit ExecStartPre, so private receipts stay private.
    /// It authorizes new starts only; it is not a watchdog for an already-running daemon.
    func packageRuntimeGuard(_ instance: String) throws {
        try requireLinuxPackageRoot()
        guard SetupPackageState.validInstance(instance), let state = try readPackageState(),
            let receipt = try readReceipt(instance), receipt.initialized,
            receipt.state != .removed
        else { throw SetupError("This package instance has no completed owned initialization.") }
        let expected: SetupPackageCompatibility
        switch state.phase {
        case .committed:
            let selectedSetupIsLive = receipt.packageSetupOwner.map(packageOwnerIsLive) == true
            guard receipt.state == .active || receipt.state == .preparing && selectedSetupIsLive,
                let incoming = state.incoming
            else {
                throw SetupError(
                    "Package configuration or its explicit live setup is not committed for this instance.")
            }
            expected = incoming
        case .configuring:
            guard state.startupPermitted.contains(instance), let owner = state.owner,
                packageOwnerIsLive(owner), let incoming = state.incoming
            else {
                throw SetupError(
                    "Package configure startup permission is absent or its owner is no longer live.")
            }
            expected = incoming
        default:
            throw SetupError("Package configuration is pending; managed boot/restart is blocked.")
        }
        let installed = try installedPackageCompatibility()
        guard installed.manifestSHA256 == expected.manifestSHA256,
            installed.version == expected.version, installed.arch == expected.arch,
            installed.canonicalFormats == expected.canonicalFormats,
            installed.semanticProfile == expected.semanticProfile,
            installed.embedding == expected.embedding,
            installed.documentExtraction == expected.documentExtraction,
            receipt.manifestSHA256 == installed.manifestSHA256
        else {
            throw SetupError("Managed startup does not identify the verified active package payload.")
        }
        try verifyRegistration(receipt)
        try verifyPeerConfigurationForLoad(receipt)
        try requireCanonicalReader(receipt, quiescent: false)
        try verifySelectedReplicaIdentity(receipt)
    }

    func packageStartupIsConfiguring(_ instance: String) throws -> Bool {
        guard roots.platform == .linux, let state = try readPackageState(), state.phase == .configuring else {
            return false
        }
        guard state.startupPermitted.contains(instance), let owner = state.owner, packageOwnerIsLive(owner)
        else {
            throw SetupError("A live configure operation must authorize this managed startup.")
        }
        return true
    }

    func authenticationDefinitionURL(_ instance: String) -> URL {
        serviceBackend.definitionURL(instance, role: .authentication)
    }
    func replaceAuthenticationRegistration(_ receipt: inout InstallationReceipt) throws {
        guard roots.platform == .linux else { return }
        let url = authenticationDefinitionURL(receipt.instance)
        if exists(url) {
            try requireOwned(url, uid: 0, directory: false)
            guard try sha256(url) == receipt.authenticationDefinitionSHA256 else {
                throw SetupError("Authentication service definition is not owned by this receipt.")
            }
        }
        let bytes = try serviceBackend.authenticationDefinition(instance: receipt.instance)
        try unloadAuthentication(receipt)
        try publishPackageDefinition(bytes, role: .authentication, receipt: &receipt)
        receipt.authenticationDefinitionSHA256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }
            .joined()
        try writeReceipt(receipt)
        try serviceBackend.load(
            receipt.instance, role: .authentication,
            enableAtBoot: !(try packageStartupIsConfiguring(receipt.instance)))
        try waitForAuthentication(receipt)
    }
    func unloadAuthentication(_ receipt: InstallationReceipt) throws {
        if roots.platform == .linux, receipt.authenticationDefinitionSHA256 != nil {
            try serviceBackend.unload(receipt.instance, role: .authentication)
        }
    }
    func loadAuthentication(_ receipt: InstallationReceipt) throws {
        guard roots.platform == .linux else { return }
        guard receipt.authenticationDefinitionSHA256 != nil else {
            throw SetupError("Owned authentication registration is missing.")
        }
        try serviceBackend.load(receipt.instance, role: .authentication)
        try waitForAuthentication(receipt)
    }
    func waitForAuthentication(_ receipt: InstallationReceipt) throws {
        if let packageAuthenticationReadiness {
            try packageAuthenticationReadiness(receipt)
            return
        }
        let path = "/run/tractanda-auth-" + receipt.instance + "/auth.sock"
        let uid = try SystemAccountDirectory().user(named: roots.platform.serviceUser).uid
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        repeat {
            var metadata = stat()
            if lstat(path, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
                metadata.st_uid == uid, metadata.st_mode & 0o777 == 0o600,
                try serviceBackend.mainPID(receipt.instance, role: .authentication) != nil
            {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw SetupError("The fixed root PAM broker did not create its owned private socket.")
    }
}
