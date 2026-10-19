#if os(Linux)
/// Exact private closure already exercised under the production install prefix.
/// This generated input is excluded from descriptor source hashes to avoid cycles.
enum ApprovedLinuxDocumentClosure {
#if arch(x86_64)
    static let sha256: String? = "8edce98a4bc2d2c3e359f79010d17c67ee08f84409ef83149f3522b0629d3cae"
#elseif arch(arm64)
    static let sha256: String? = "26fa7c7735ee62b725fbb628e17f32f5b4f340ee47a89f89eb438bafaa886ae5"
#else
    static let sha256: String? = nil
#endif
    static let installPrefix = "/opt/tractanda/current"
    static let owner: UInt32 = 0
}
#endif
