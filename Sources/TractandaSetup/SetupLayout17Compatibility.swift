import Foundation
import TractandaCore

/// Finite package check for the .16.2 to .17 physical-layout bridge only.
/// It does not authenticate either payload, establish administrator intent, or
/// prove quiescence. Callers must independently establish those conditions.
extension SetupPackageCompatibility {
    func requireLayout17Transition(from old: Self) throws {
        try validate()
        try old.validate()
        let capabilities: Set<String> = ["tractanda.physical-layout.flat-items.v1", "tractanda.message-items.v1"]
        let before = old.canonicalFormats
        let after = canonicalFormats
        guard old.version == "0.1.0-poc.16.2", version == "0.1.0-poc.17",
            old.upgrade == .compatible, upgrade == .coordinatedMaintenance,
            old.arch == arch, old.semanticProfile == semanticProfile,
            semanticProfile == PeerCompatibilityDeclaration.semanticProfile,
            old.embedding == embedding,
            try old.documentExtraction?.identity.storedSemanticProfile()
                == documentExtraction?.identity.storedSemanticProfile(),
            before.readerLevel == 18, before.writerLevel == 18,
            after.readerLevel == 20, after.writerLevel == 20,
            before.profile == after.profile, before.read == after.read, before.write == after.write,
            capabilities.isDisjoint(with: Set(before.capabilities)),
            capabilities.isDisjoint(with: Set(before.writeCapabilities)),
            Set(after.capabilities) == Set(before.capabilities).union(capabilities),
            Set(after.writeCapabilities) == Set(before.writeCapabilities).union(capabilities)
        else {
            throw SetupError("The package is not the exact .16.2 to .17 physical-layout transition.")
        }
    }
}
