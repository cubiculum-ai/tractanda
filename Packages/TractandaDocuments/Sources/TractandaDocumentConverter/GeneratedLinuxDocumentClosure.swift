#if os(Linux)
    /// Exact private closure already exercised under the production install prefix.
    /// This compiler input remains in descriptor source hashes; only architecture
    /// digest literals are normalized to avoid self-reference.
    enum ApprovedLinuxDocumentClosure {
        #if arch(x86_64)
            static let sha256: String? = "610fdf77f4d8f037ec0d6510d50023e9e8d02f79a36236e044e446150ffca013"
        #elseif arch(arm64)
            static let sha256: String? = "b40ec16204a9d32c59bb50302aeec5fabf03245e21a7a35c0a7a166af2674c92"
        #else
            static let sha256: String? = nil
        #endif
        static let installPrefix = "/opt/tractanda/current"
        static let owner: UInt32 = 0
    }
#endif
