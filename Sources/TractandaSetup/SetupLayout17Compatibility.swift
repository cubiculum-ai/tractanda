import Foundation
import TractandaCore

/// The two releases that carry the finite physical-layout bridge.
enum SetupLayout17Release {
    static let source = "0.1.0-poc.16.2"
    static let first = "0.1.0-poc.17"
    static let corrected = "0.1.0-poc.17.1"

    static func upgrade(for version: String) -> SetupPackageCompatibility.Upgrade? {
        switch version {
        case first: .coordinatedMaintenance
        case corrected: .compatible
        default: nil
        }
    }
}

/// Finite package check for the .16.2 to .17-family physical-layout bridge.
/// It does not authenticate either payload, establish administrator intent, or
/// prove quiescence. Callers must independently establish those conditions.
extension SetupPackageCompatibility {
    func requireLayout17Transition(from old: Self) throws {
        try validate()
        try old.validate()
        let capabilities: Set<String> = [
            "tractanda.physical-layout.flat-items.v1", "tractanda.message-items.v1",
        ]
        let before = old.canonicalFormats
        let after = canonicalFormats
        guard let policy = SetupLayout17Release.upgrade(for: version),
            old.version == SetupLayout17Release.source,
            old.upgrade == .compatible, upgrade == policy,
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

    func requireLayout17CompatibleUpdate(from old: Self) throws {
        guard old.version == SetupLayout17Release.first,
            old.upgrade == .coordinatedMaintenance, version == SetupLayout17Release.corrected,
            canonicalFormats == old.canonicalFormats,
            canonicalFormats.readerLevel == 20, canonicalFormats.writerLevel == 20
        else { throw SetupError("The installed .17 update must retain its exact current canonical formats.") }
        try requireRollingUpgrade(from: old)
    }
}
