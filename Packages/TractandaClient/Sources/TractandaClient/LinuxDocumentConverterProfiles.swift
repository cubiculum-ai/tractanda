/// Selects an execution build, independent of the operating system doing inspection.
public enum LinuxBuildBaseline: String, Codable, Sendable {
    case debian13
    case kaliRolling = "kali-rolling"

    public static var compiled: Self {
        #if TRACTANDA_KALI_ROLLING
            .kaliRolling
        #else
            .debian13
        #endif
    }
}

/// Finite current package profile. Saved-data readability does not consult it;
/// current subprocess results still require this platform's exact identity.
enum LinuxDocumentConverterProfiles {
    static let macConverter = "tractanda.docling-native.v2-idefics3-gelu-f32"
    /// Only current local package/worker admission uses the compiled digest.
    /// Saved identities are validated independently by their stored semantics.
    static func converterName(digest: String?) -> String? {
        guard let digest, digest.utf8.count == 64,
            digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { return nil }
        return macConverter + "+linux-raster." + digest
    }
    static func digest(architecture: String, baseline: LinuxBuildBaseline) -> String? {
        switch (baseline, architecture) {
        case (.debian13, "amd64"), (.debian13, "x86_64"):
            GeneratedLinuxDocumentConverterDigests.amd64
        case (.debian13, "arm64"):
            GeneratedLinuxDocumentConverterDigests.arm64
        case (.kaliRolling, "amd64"), (.kaliRolling, "x86_64"):
            GeneratedLinuxDocumentConverterDigests.kaliAMD64
        case (.kaliRolling, "arm64"):
            GeneratedLinuxDocumentConverterDigests.kaliARM64
        default: nil
        }
    }
    static var currentConverter: String {
        #if os(Linux) && arch(x86_64)
            let digest = Self.digest(architecture: "amd64", baseline: .compiled)
        #elseif os(Linux) && arch(arm64)
            let digest = Self.digest(architecture: "arm64", baseline: .compiled)
        #else
            let digest: String? = nil
        #endif
        // A nil entry never authorizes rendering: LinuxNativeAdmission also
        // requires the matching compiled closure before command dispatch.
        return converterName(digest: digest) ?? macConverter
    }
}
