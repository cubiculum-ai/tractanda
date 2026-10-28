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
        let runner = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        guard runner.pathExtension == "xctest" else {
            throw TractandaError("fixture", "Cannot identify the current SwiftPM test executable.")
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
