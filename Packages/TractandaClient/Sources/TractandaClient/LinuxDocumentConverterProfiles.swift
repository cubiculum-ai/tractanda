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
    static var currentConverter: String {
        #if os(Linux) && arch(x86_64)
            let digest = GeneratedLinuxDocumentConverterDigests.amd64
        #elseif os(Linux) && arch(arm64)
            let digest = GeneratedLinuxDocumentConverterDigests.arm64
        #else
            let digest: String? = nil
        #endif
        // A nil entry never authorizes rendering: LinuxNativeAdmission also
        // requires the matching compiled closure before command dispatch.
        guard let digest else { return macConverter }
        return macConverter + "+linux-raster." + digest
    }
}
