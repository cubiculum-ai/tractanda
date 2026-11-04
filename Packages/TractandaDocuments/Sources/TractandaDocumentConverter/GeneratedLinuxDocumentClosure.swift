#if os(Linux)
    /// Exact private closure already exercised under the production install prefix.
    /// This compiler input remains in descriptor source hashes; only architecture
    /// digest literals are normalized to avoid self-reference.
    enum ApprovedLinuxDocumentClosure {
        #if arch(x86_64)
            static let sha256: String? = "547068226182eabc915f5f998c0f520232b73bff90a82bd5d37a71a276f85fd9"
        #elseif arch(arm64)
            static let sha256: String? = "2540c30d82393cafd57912a27fef0e61a368330b108a17380fdf62ed9bca2d5d"
        #else
            static let sha256: String? = nil
        #endif
        static let installPrefix = "/opt/tractanda/current"
        static let owner: UInt32 = 0
    }
#endif
