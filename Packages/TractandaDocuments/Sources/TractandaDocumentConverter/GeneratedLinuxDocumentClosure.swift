#if os(Linux)
    /// Exact private closure already exercised under the production install prefix.
    /// This compiler input remains in descriptor source hashes; only architecture
    /// digest literals are normalized to avoid self-reference.
    enum ApprovedLinuxDocumentClosure {
        #if arch(x86_64)
            static let sha256: String? = "70c4dccbc9ba294a0b4effea7e2f47005fea85f4155f8587adc8987c6806b726"
        #elseif arch(arm64)
            static let sha256: String? = "3656ce0831bd76ade008db31dded22b78058a4c60c0f7342bb0de3faab797ff7"
        #else
            static let sha256: String? = nil
        #endif
        static let installPrefix = "/opt/tractanda/current"
        static let owner: UInt32 = 0
    }
#endif
