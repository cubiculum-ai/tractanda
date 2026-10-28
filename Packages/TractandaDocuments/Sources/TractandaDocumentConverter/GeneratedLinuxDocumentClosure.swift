#if os(Linux)
    /// Exact private closure already exercised under the production install prefix.
    /// This compiler input remains in descriptor source hashes; only architecture
    /// digest literals are normalized to avoid self-reference.
    enum ApprovedLinuxDocumentClosure {
        #if arch(x86_64)
            static let sha256: String? = "cf0762a6d3500973c98ca565efd931e63218fe1a8c6975398145c066c3581fcd"
        #elseif arch(arm64)
            static let sha256: String? = "b005e3a10f5ad01498f5691e9109c977655d6fca31e57a26d794b9433ff48b88"
        #else
            static let sha256: String? = nil
        #endif
        static let installPrefix = "/opt/tractanda/current"
        static let owner: UInt32 = 0
    }
#endif
