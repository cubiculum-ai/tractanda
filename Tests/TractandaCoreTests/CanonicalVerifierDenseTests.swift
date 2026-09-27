import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class CanonicalVerifierDenseTests: XCTestCase {
    private actor Findings {
        private var values: [CanonicalVerifier.Finding] = []
        func append(_ batch: [CanonicalVerifier.Finding]) { values.append(contentsOf: batch) }
        func all() -> [CanonicalVerifier.Finding] { values }
    }

    private func capacityCheck(root: URL, fixtureBytes: UInt64, nextDirectoryCount: Int) throws {
        let perDirectory = UInt64(4_096)
        let (nextBytes, overflow) = UInt64(nextDirectoryCount).multipliedReportingOverflow(by: perDirectory)
        guard !overflow, fixtureBytes <= 8 * 1024 * 1024,
            nextBytes <= 8 * 1024 * 1024 - fixtureBytes
        else { throw TractandaError("fixtureLimit", "Dense verifier fixture exceeds its small cap.") }
        var status = statvfs()
        guard root.path.withCString({ statvfs($0, &status) }) == 0 else {
            throw TractandaError("fixtureCapacity", "Cannot determine available fixture capacity.")
        }
        let (available, overflowed) = UInt64(status.f_bavail)
            .multipliedReportingOverflow(by: UInt64(status.f_frsize))
        let reserve = UInt64(10) * 1024 * 1024 * 1024
        guard !overflowed, available >= reserve + nextBytes else {
            throw TractandaError("fixtureCapacity", "Dense fixture would cross the free-space reserve.")
        }
    }

    private func openStore(_ root: URL) throws -> ItemStore {
        try ItemStore(root: root)
    }

    func testDenseItemDirectoryFanoutCompletesWithBoundedDescriptorDepth() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: root) }
        var store: ItemStore? = try openStore(root)
        let itemsRoot = store!.root.appendingPathComponent("items", isDirectory: true)
        let bucket = itemsRoot.appendingPathComponent("2026/09/27/12/00", isDirectory: true)
        let directoryCount = 513
        try capacityCheck(
            root: store!.root, fixtureBytes: 0, nextDirectoryCount: directoryCount + 5)
        try FileManager.default.createDirectory(at: bucket, withIntermediateDirectories: true)
        var ancestor = bucket
        while ancestor.path.hasPrefix(itemsRoot.path + "/") {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ancestor.path)
            ancestor.deleteLastPathComponent()
        }
        let snapshot = try store!.verificationSnapshot()
        var created = 0
        for start in stride(from: 0, to: directoryCount, by: 32) {
            let batchCount = min(32, directoryCount - start)
            try capacityCheck(
                root: store!.root, fixtureBytes: UInt64(created + 5) * 4_096,
                nextDirectoryCount: batchCount)
            for _ in 0..<batchCount {
                let directory = bucket.appendingPathComponent(Identifier.make(), isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o700], ofItemAtPath: directory.path)
                created += 1
            }
            try capacityCheck(
                root: store!.root, fixtureBytes: UInt64(created + 5) * 4_096,
                nextDirectoryCount: 0)
        }
        store = nil

        let findings = Findings()
        let result = await CanonicalVerifier.scan(snapshot) { await findings.append($0) }
        let collected = await findings.all()
        XCTAssertEqual(result.status, .complete)
        XCTAssertEqual(result.exactCatalogueCount, 0)
        XCTAssertEqual(result.exactFindingCount, 0)
        XCTAssertFalse(collected.contains { $0.kind == .missing })
        XCTAssertLessThanOrEqual(
            result.resources.peakPendingDirectories, CanonicalVerifier.pendingDirectoryLimit)
    }

    func testCancellationIsReportedCancelledWithoutExactOrMissingResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: root) }
        var store: ItemStore? = try openStore(root)
        let marker = store!.root.appendingPathComponent("items/cancellation-marker", isDirectory: true)
        try capacityCheck(root: store!.root, fixtureBytes: 0, nextDirectoryCount: 1)
        try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: marker.path)
        let snapshot = try store!.verificationSnapshot()
        store = nil

        let findings = Findings()
        let result = await CanonicalVerifier.scan(
            snapshot,
            readMetadata: { url in
                withUnsafeCurrentTask { $0?.cancel() }
                return try FileMetadata.read(at: url)
            },
            onFindings: { await findings.append($0) })
        let collected = await findings.all()
        XCTAssertEqual(result.status, .cancelled)
        XCTAssertNil(result.exactCatalogueCount)
        XCTAssertNil(result.exactFindingCount)
        XCTAssertFalse(collected.contains { $0.kind == .missing })
    }
}
