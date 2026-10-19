import Foundation

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

enum AttachmentFixtureCapacity {
    static let reserveBytes: UInt64 = 10 * 1024 * 1024 * 1024
    static let fixtureCapBytes: UInt64 = 128 * 1024 * 1024
    static func requireFree(at suppliedDirectory: URL? = nil) throws {
        let directory = try suppliedDirectory ?? GuardedFixtureDirectory.parent()
        var status = statvfs()
        guard statvfs(directory.path, &status) == 0, status.f_frsize > 0 else {
            throw TractandaError("resourceLimit", "Genuine fixture capacity unavailable.")
        }
        let available = UInt64(status.f_bavail).multipliedReportingOverflow(by: UInt64(status.f_frsize))
        guard !available.overflow, available.partialValue >= reserveBytes + fixtureCapBytes else {
            throw TractandaError(
                "resourceLimit", "Tiny fixture requires 10GiB reserve and 128MiB clustering cap.")
        }
    }
}
