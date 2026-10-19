/// Finite compiled renderer profiles. Historical metadata remains readable;
/// current subprocess results still require this platform's exact identity.
enum LinuxDocumentConverterProfiles {
    static let macConverter = "tractanda.docling-native.v2-idefics3-gelu-f32"
    // Retain each formerly admitted Linux profile here when current bundled
    // dependencies change. This grants history readability, never execution.
    static let historicalLinuxDigests: [String] = []
    static var knownConverters: [String] {
        converterNames(currentDigests: [GeneratedLinuxDocumentConverterDigests.amd64,
            GeneratedLinuxDocumentConverterDigests.arm64], historicalDigests: historicalLinuxDigests)
    }
    static func converterNames(currentDigests: [String?], historicalDigests: [String]) -> [String] {
        (currentDigests + historicalDigests.map(Optional.some)).compactMap { digest in
            guard let digest, digest.utf8.count == 64,
                digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
            return macConverter + "+linux-raster." + digest
        }
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
