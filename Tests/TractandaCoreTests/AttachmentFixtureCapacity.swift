import Foundation

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Tiny attachment fixtures reserve genuine free blocks, separately from the product reserve.
enum AttachmentFixtureCapacity {
    static let reserveBytes: Int64 = 10 * 1024 * 1024 * 1024
    static let fixtureCapBytes: UInt64 = 32 * 1024 * 1024
    static func requireFree(at directory: URL = FileManager.default.temporaryDirectory) throws {
        var capacity = statvfs()
        guard statvfs(directory.path, &capacity) == 0, capacity.f_frsize > 0 else {
            throw TractandaError("resourceLimit", "Cannot inspect attachment fixture capacity.")
        }
        let available = UInt64(capacity.f_bavail).multipliedReportingOverflow(by: UInt64(capacity.f_frsize))
        guard !available.overflow, available.partialValue >= UInt64(reserveBytes) + fixtureCapBytes else {
            throw TractandaError(
                "resourceLimit",
                "Tiny attachment fixtures need a genuine 10 GiB reserve plus their 32 MiB cap.")
        }
    }
    static func makeStore(
        root: URL, indexDirectory: URL? = nil,
        accounts: any AccountDirectory = SystemAccountDirectory()
    ) throws -> ItemStore {
        try requireFree()
        let store = try ItemStore(root: root, indexDirectory: indexDirectory, accounts: accounts)
        try store.setAttachmentReserveForTesting(reserveBytes)
        return store
    }
}
