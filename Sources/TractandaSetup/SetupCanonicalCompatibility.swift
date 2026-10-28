import Foundation
import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

extension SetupEngine {
    func verifiedCanonicalSupport(release: URL, expectedDigest: String) throws -> CanonicalFormatSupport {
        guard try sha256(release.appendingPathComponent("bundle-manifest.json")) == expectedDigest else {
            throw SetupError("Canonical reader declaration differs from the owned release receipt.")
        }
        let manifest = try verifyBundle(at: release)
        return manifest.canonicalFormats ?? .legacy
    }
    private func canonicalOwnerUID(_ root: URL) throws -> UInt32 {
        if trustedOwnership {
            return try SystemAccountDirectory().user(named: roots.platform.serviceUser).uid
        }
        guard
            let owner = try FileManager.default.attributesOfItem(atPath: root.path)[.ownerAccountID]
                as? NSNumber
        else {
            throw SetupError("Canonical root ownership proof is unavailable.")
        }
        return owner.uint32Value
    }
    /// The candidate/previous service is stopped. A missing requirement is never guessed.
    func quiescentCanonicalRequirement(_ receipt: InstallationReceipt) throws -> CanonicalReaderRequirement {
        let root = URL(fileURLWithPath: receipt.store).resolvingSymlinksInPath()
        let uid = try canonicalOwnerUID(root)
        return try CanonicalReaderRequirement.withWriterLock(root: root, ownerUID: uid) {
            try ItemStore.personalWorkgroupUpgradeRequirement(root: root, ownerUID: uid)
        }
    }
    func requireCanonicalReader(_ receipt: InstallationReceipt, quiescent: Bool) throws {
        let support = try verifiedCanonicalSupport(
            release: URL(fileURLWithPath: receipt.release), expectedDigest: receipt.manifestSHA256)
        let root = URL(fileURLWithPath: receipt.store).resolvingSymlinksInPath()
        try ItemStore.verifyPersonalWorkgroupRoot(root: root, ownerUID: canonicalOwnerUID(root))
        let required: CanonicalReaderRequirement
        if quiescent {
            required = try quiescentCanonicalRequirement(receipt)
        } else {
            guard
                let proof = try CanonicalReaderRequirement.load(root: root, ownerUID: canonicalOwnerUID(root))
            else {
                throw SetupError(
                    "Canonical reader proof is missing; stop the writer and retry with a compatible installer."
                )
            }
            required = proof
        }
        try support.require(required)
    }
    /// Guard a global client link against both durable data and every active writer's possible
    /// future formats. Installer lock serializes registration changes; writers need not stop.
    func requireSharedClientReader(_ release: String, excludingStoppedInstance: String? = nil) throws {
        let receipts = try installationReceipts().filter { $0.state != .removed }
        guard let owner = receipts.first(where: { $0.releases[release] != nil }),
            let digest = owner.releases[release]
        else {
            throw SetupError("Shared client reader is not an owned release.")
        }
        let reader = try verifiedCanonicalSupport(
            release: URL(fileURLWithPath: release), expectedDigest: digest)
        for receipt in receipts {
            if receipt.instance == excludingStoppedInstance {
                let running = try serviceBackend.isRunning(receipt.instance)
                guard !running, !exists(definitionURL(receipt.instance)) else {
                    throw SetupError(
                        "Uninstall target must be stopped and deregistered before shared client retargeting.")
                }
                continue
            }
            let root = URL(fileURLWithPath: receipt.store).resolvingSymlinksInPath()
            try ItemStore.verifyPersonalWorkgroupRoot(root: root, ownerUID: canonicalOwnerUID(root))
            guard
                let proof = try CanonicalReaderRequirement.load(root: root, ownerUID: canonicalOwnerUID(root))
            else {
                throw SetupError("Shared client rollback blocked by missing store compatibility proof.")
            }
            try reader.require(proof)
            let running = try serviceBackend.isRunning(receipt.instance)
            if receipt.state == .active || receipt.definitionSHA256 != nil || running {
                guard receipt.definitionSHA256 != nil else {
                    throw SetupError("Running writer declaration cannot be bound to an owned registration.")
                }
                let writer = try verifiedCanonicalSupport(
                    release: URL(fileURLWithPath: receipt.release), expectedDigest: receipt.manifestSHA256)
                try verifyRegistration(receipt)
                try reader.requireWriter(writer)
            }
        }
    }
    func verifyCanonicalReadiness(_ receipt: InstallationReceipt, info: [String: Any]) throws {
        let expected = try verifiedCanonicalSupport(
            release: URL(fileURLWithPath: receipt.release), expectedDigest: receipt.manifestSHA256)
        let observed: CanonicalFormatSupport
        if let object = info["canonicalFormats"] {
            observed = try JSONDecoder().decode(
                CanonicalFormatSupport.self, from: JSONSerialization.data(withJSONObject: object))
        } else {
            observed = .legacy
        }
        guard observed == expected else {
            throw SetupError("Runtime canonical format support differs from the signed bundle.")
        }
        guard info["persistenceProfile"] as? String == "personal-workgroup",
            let clustering = info["clustering"] as? [String: Any],
            let clusteringState = clustering["state"] as? String,
            ["standalone", "configured"].contains(clusteringState),
            clustering["profile"] as? String == "tractanda.personal-sync.v1",
            let activeObject = info["activeCanonicalFormats"],
            try JSONDecoder().decode(
                CanonicalFormatSupport.self,
                from: JSONSerialization.data(withJSONObject: activeObject)) == .personalWorkgroup
        else {
            throw SetupError("Runtime personal/workgroup profile or active capability declaration differs.")
        }
        try requireCanonicalReader(receipt, quiescent: false)
    }
    func blockCanonicalRollback(_ receipt: inout InstallationReceipt, error: Error) throws {
        _ = removeOwnedRegistration(definitionURL(receipt.instance), expectedSHA256: receipt.definitionSHA256)
        _ = removeOwnedRegistration(
            embeddingDefinitionURL(receipt.instance), expectedSHA256: receipt.embeddingDefinitionSHA256)
        receipt.state = .preparing
        receipt.definitionSHA256 = nil
        receipt.embeddingDefinitionSHA256 = nil
        receipt.recoveryReason =
            "Canonical reader rollback blocked. Keep data/backups intact and retry with a compatible reader. "
            + error.localizedDescription
        try writeReceipt(receipt)
    }
}
