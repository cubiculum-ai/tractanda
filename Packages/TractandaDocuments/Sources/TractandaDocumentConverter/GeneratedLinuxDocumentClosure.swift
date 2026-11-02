#if os(Linux)
    /// Exact private closure already exercised under the production install prefix.
    /// This compiler input remains in descriptor source hashes; only architecture
    /// digest literals are normalized to avoid self-reference.
    enum ApprovedLinuxDocumentClosure {
        #if arch(x86_64)
            static let sha256: String? = "22e7bc49253aaf81602d5dca2fb61a8c6acab4d529e7a8e4416628f5637e53aa"
        #elseif arch(arm64)
            static let sha256: String? = "d4ddcdac08f8eb4dfe70646be62d2e5e6554d60e337ad7e1bffafbaad4895861"
        #else
            static let sha256: String? = nil
        #endif
        static let installPrefix = "/opt/tractanda/current"
        static let owner: UInt32 = 0
    }
#endif
