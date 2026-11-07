#if os(Linux)
    /// Exact private closure already exercised under the production install prefix.
    /// This compiler input remains in descriptor source hashes. Only exact baseline
    /// and architecture digest slots are normalized to avoid self-reference.
    enum ApprovedLinuxDocumentClosure {
        static let kaliAMD64: String? = "dfff10e7ae933b5e8eb3c0840dec58f04b681979d68a8c113ff5e1171ef9e453"
        static let kaliARM64: String? = "a46387cb7ebc1e50d74d2134803e3898f575820d40b3fc252203970f8864abbd"
        #if arch(x86_64)
            static let sha256: String? = "4d5b73350265f8c8d00fd14c84bb52865a218113ecf4407d500c021e55cc5f44"
            static let kaliSHA256 = kaliAMD64
        #elseif arch(arm64)
            static let sha256: String? = "fc12ebc137327bb8a9cecabde2a8334cbadc8ab132f2af59eaad53e73a6ed814"
            static let kaliSHA256 = kaliARM64
        #else
            static let sha256: String? = nil
            static let kaliSHA256: String? = nil
        #endif
        static var activeSHA256: String? {
            #if TRACTANDA_KALI_ROLLING
                kaliSHA256
            #else
                sha256
            #endif
        }
        static let installPrefix = "/opt/tractanda/current"
        static let owner: UInt32 = 0
    }
#endif
