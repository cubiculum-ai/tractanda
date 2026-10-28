/// Finite compiled renderer profiles. Historical metadata remains readable;
/// current subprocess results still require this platform's exact identity.
enum LinuxDocumentConverterProfiles {
    static let macConverter = "tractanda.docling-native.v2-idefics3-gelu-f32"
    // Retain each formerly admitted Linux profile here when current bundled
    // dependencies change. This grants history readability, never execution.
    static let historicalLinuxDigests: [String] = [
        "8edce98a4bc2d2c3e359f79010d17c67ee08f84409ef83149f3522b0629d3cae",
        "26fa7c7735ee62b725fbb628e17f32f5b4f340ee47a89f89eb438bafaa886ae5",
    ]
    static var knownConverters: [String] {
        converterNames(
            currentDigests: [
                GeneratedLinuxDocumentConverterDigests.amd64,
                GeneratedLinuxDocumentConverterDigests.arm64,
            ], historicalDigests: historicalLinuxDigests)
    }
    static func converterNames(currentDigests: [String?], historicalDigests: [String]) -> [String] {
        (currentDigests + historicalDigests.map(Optional.some)).compactMap { digest in
            guard let digest, digest.utf8.count == 64,
                digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            else { return nil }
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
