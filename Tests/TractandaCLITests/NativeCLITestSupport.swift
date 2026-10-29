import Foundation
import TractandaCore

/// Bind CLI integration tests to the executable beside the currently running SwiftPM test product.
/// A native owner may name that same product explicitly; installed or arbitrary old binaries are refused.
func currentBuiltTestCLI(anchor: AnyClass) throws -> URL {
    let products: URL
    #if os(macOS)
        let bundle = Bundle(for: anchor).bundleURL
        guard bundle.pathExtension == "xctest" else {
            throw TractandaError("fixture", "Cannot identify the current SwiftPM test product.")
        }
        products = bundle.deletingLastPathComponent()
    #else
        // SwiftPM may supply an argv[0] label without the old .xctest suffix.
        // The kernel image identifies the actual running test, never a PATH alias.
        let path = try FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")
        guard path.hasPrefix("/"), !path.hasSuffix(" (deleted)") else {
            throw TractandaError("fixture", "Cannot identify the current kernel test executable.")
        }
        let runner = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        // Accept this target's Swift Build runner or the native SwiftPM test
        // product, rather than guessing a build-metadata directory layout.
        let testProducts = [
            "TractandaCLITests", "TractandaCLITests.xctest", "TractandaPackageTests.xctest",
        ]
        let image = try runner.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard testProducts.contains(runner.lastPathComponent), image.isRegularFile == true,
            image.isSymbolicLink != true, FileManager.default.isExecutableFile(atPath: runner.path)
        else {
            throw TractandaError("fixture", "The kernel image is not this SwiftPM test product.")
        }
        products = runner.deletingLastPathComponent()
    #endif
    let executable = products.appendingPathComponent("tractanda")
    let metadata = try executable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard metadata.isRegularFile == true, metadata.isSymbolicLink != true,
        FileManager.default.isExecutableFile(atPath: executable.path)
    else {
        throw TractandaError("fixture", "The current SwiftPM build did not produce its tractanda executable.")
    }
    if let supplied = ProcessInfo.processInfo.environment["TRACTANDA_TEST_CLI"] {
        guard supplied.hasPrefix("/"),
            URL(fileURLWithPath: supplied).resolvingSymlinksInPath() == executable.resolvingSymlinksInPath()
        else {
            throw TractandaError("fixture", "TRACTANDA_TEST_CLI must identify this test build's executable.")
        }
    }
    return executable
}
