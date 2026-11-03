import Foundation
import TractandaCore

/// Finite package check for the .16.2 to .17 physical-layout bridge only.
/// It does not authenticate either payload, establish administrator intent, or
/// prove quiescence. Callers must independently establish those conditions.
extension SetupPackageCompatibility {
    func requireLayout17Transition(from old: Self) throws {
        try validate()
        try old.validate()
        let capability = "tractanda.physical-layout.flat-items.v1"
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
            after.readerLevel == 19, after.writerLevel == 19,
            before.profile == after.profile, before.read == after.read, before.write == after.write,
            !before.capabilities.contains(capability), !before.writeCapabilities.contains(capability),
            Set(after.capabilities) == Set(before.capabilities).union([capability]),
            Set(after.writeCapabilities) == Set(before.writeCapabilities).union([capability])
        else {
            throw SetupError("The package is not the exact .16.2 to .17 physical-layout transition.")
        }
    }
}
