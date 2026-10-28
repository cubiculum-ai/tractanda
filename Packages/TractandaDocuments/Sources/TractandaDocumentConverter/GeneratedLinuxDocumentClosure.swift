#if os(Linux)
    /// Exact private closure already exercised under the production install prefix.
    /// This compiler input remains in descriptor source hashes; only architecture
    /// digest literals are normalized to avoid self-reference.
    enum ApprovedLinuxDocumentClosure {
        #if arch(x86_64)
            static let sha256: String? = "dfa09494f380c6093469e24d701452526f27a2789272a5d25a421329845fbaee"
        #elseif arch(arm64)
            static let sha256: String? = "561cd6cf1835ff00a6b9b0bb39998665a78e52d2dcba0dad4bc88e55fda65538"
        #else
            static let sha256: String? = nil
        #endif
        static let installPrefix = "/opt/tractanda/current"
        static let owner: UInt32 = 0
    }
#endif
