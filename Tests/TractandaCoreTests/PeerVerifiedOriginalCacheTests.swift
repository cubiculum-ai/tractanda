import CTractandaPlatform
import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class PeerVerifiedOriginalCacheTests: XCTestCase {
    private typealias Fixture = PeerIntakeStoreTests.Fixture
    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add(_ amount: Int) {
            lock.lock()
            count += amount
            lock.unlock()
        }
        var bytes: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }
    private func withOriginal(
        _ body: (Fixture, PeerIntakeCoordinator, ItemIndex, AuthorityStore.RetainedObject) throws -> Void
    ) throws {
        let f = try Fixture()
        try f.bootstrap()
        let original = try f.source.commit(
            .init(
                classID: "Item", changes: ["subject": .text("Verified raw reuse")], operationID: Fixture.id())
        ).revision
        let index = try ItemIndex(
            path: f.sourceRoot.appendingPathComponent("index/items.sqlite").path, create: false)
        defer { index.close() }
        let row = try XCTUnwrap(index.retainedAuthorityObject(id: original.revisionID))
        let c = PeerIntakeCoordinator(root: f.sourceRoot, ownerUID: tractanda_uid(), storeID: f.storeID)
        try body(f, c, index, row)
        try f.capacity()
    }
    func testRepeatedHydrationReadsAndChargesOriginalOncePerOperation() throws {
        try withOriginal { f, c, _, row in
            let probe = Reads()
            let observedPath = row.path
            try DocumentContentFiles.observeReadsForTesting(
                root: f.sourceRoot,
                observation: { path, bytes in
                    if path.joined(separator: "/") == observedPath { probe.add(bytes) }
                },
                body: {
                    for _ in 0..<2 {
                        try c.withOperation {
                            let first = try c.bytes(row)
                            for _ in 0..<12 { XCTAssertEqual(try c.bytes(row), first) }
                            XCTAssertEqual(c.operationReadBytesForTesting, UInt64(row.descriptor.length))
                            XCTAssertEqual(c.verifiedOriginalCacheForTesting.entries, 1)
                        }
                        XCTAssertEqual(c.verifiedOriginalCacheForTesting.bytes, 0)
                    }
                })
            XCTAssertEqual(probe.bytes, row.descriptor.length * 2)
        }
    }
    func testMutationMissingSymlinkHardlinkAndCustodyChangesFailClosedOnHit() throws {
        for scenario in ["mutation", "missing", "symlink", "hardlink", "custody"] {
            try withOriginal { f, c, _, row in
                let file = f.sourceRoot.appendingPathComponent(row.path)
                if scenario == "mutation" {
                    // Historical originals may be0600. Make a real same-file mutation possible,
                    // then restore an exactly representable mtime so ctime remains significant.
                    XCTAssertEqual(chmod(file.path, 0o600), 0)
                    try FileManager.default.setAttributes(
                        [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
                        ofItemAtPath: file.path)
                }
                try c.withOperation {
                    let original = try c.bytes(row)
                    switch scenario {
                    case "mutation":
                        let saved = try FileManager.default.attributesOfItem(atPath: file.path)[
                            .modificationDate]
                        var bytes = original
                        bytes[bytes.startIndex] ^= 1
                        try bytes.write(to: file)
                        if let saved {
                            try FileManager.default.setAttributes(
                                [.modificationDate: saved], ofItemAtPath: file.path)
                        }
                    case "missing": try FileManager.default.removeItem(at: file)
                    case "symlink":
                        let retained = f.directory.appendingPathComponent("retained")
                        try FileManager.default.moveItem(at: file, to: retained)
                        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: retained)
                    case "hardlink":
                        XCTAssertEqual(link(file.path, f.directory.appendingPathComponent("linked").path), 0)
                    default: XCTAssertEqual(chmod(file.path, 0o644), 0)
                    }
                    XCTAssertThrowsError(try c.bytes(row), scenario) {
                        XCTAssertEqual(($0 as? TractandaError)?.code, "peerObjectCollision")
                    }
                    XCTAssertThrowsError(
                        try c.bytes(row), "An invalidated entry cannot regain trust inside this operation")
                }
                XCTAssertEqual(c.verifiedOriginalCacheForTesting.bytes, 0)
            }
        }
    }
    func testErrorAndCancellationClearOwnerScope() throws {
        for code in ["cancelled", "probeFailure"] {
            try withOriginal { _, c, _, row in
                XCTAssertThrowsError(
                    try c.withOperation {
                        _ = try c.bytes(row)
                        throw TractandaError(code, "Tiny scope unwind probe")
                    })
                XCTAssertEqual(c.verifiedOriginalCacheForTesting.entries, 0)
                try c.withOperation {
                    _ = try c.bytes(row)
                    XCTAssertEqual(c.operationReadBytesForTesting, UInt64(row.descriptor.length))
                }
            }
        }
    }
    func testNestedExplicitWindowsDoNotBorrowCacheOrRestoreConsumedQuota() throws {
        try withOriginal { _, c, _, row in
            let length = UInt64(row.descriptor.length)
            try c.withOperation(maximumReadBytes: length * 4) {
                let bytes = try c.bytes(row)
                XCTAssertThrowsError(try c.withOperation(maximumReadBytes: length - 1) { try c.bytes(row) }) {
                    XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
                }
                try c.withOperation(maximumReadBytes: length * 2) {
                    XCTAssertEqual(try c.bytes(row), bytes)
                    XCTAssertEqual(try c.bytes(row), bytes)
                    XCTAssertEqual(c.operationReadBytesForTesting, length * 2)
                }
                XCTAssertEqual(c.operationReadBytesForTesting, length * 3)
                XCTAssertEqual(try c.bytes(row), bytes)
                XCTAssertEqual(c.operationReadBytesForTesting, length * 3)
            }
            XCTAssertEqual(c.verifiedOriginalCacheForTesting.entries, 0)
        }
    }
    func testResidentEntryAndByteBoundsDoNotStopUncachedReads() throws {
        try withOriginal { f, c, _, row in
            for (byteLimit, entryLimit, expectedLoads) in [
                (row.descriptor.length - 1, 1, 2), (row.descriptor.length, 0, 2),
                (row.descriptor.length, 1, 1),
            ] {
                let cache = PeerVerifiedOriginalCache(
                    root: f.sourceRoot, ownerUID: tractanda_uid(), maximumBytes: byteLimit,
                    maximumEntries: entryLimit)
                var loads = 0
                for _ in 0..<2 {
                    _ = try cache.read(row) {
                        loads += 1
                        return try c.bytes(row)
                    }
                }
                XCTAssertEqual(loads, expectedLoads)
                XCTAssertLessThanOrEqual(cache.residentBytes, byteLimit)
                XCTAssertLessThanOrEqual(cache.entryCount, entryLimit)
            }
        }
    }
    func testReuseHonorsProgressCancellation() throws {
        try withOriginal { _, c, _, row in
            XCTAssertThrowsError(
                try c.withOperation {
                    _ = try c.bytes(row)
                    c.progress = { throw CancellationError() }
                    _ = try c.bytes(row)
                }
            ) { XCTAssertTrue($0 is CancellationError) }
            c.progress = nil
            XCTAssertEqual(c.verifiedOriginalCacheForTesting.entries, 0)
        }
    }
    func testReuseHonorsActualTaskCancellationWithoutProgressCallback() async throws {
        let task = Task { () throws -> Bool in
            let f = try Fixture()
            try f.bootstrap()
            let index = try ItemIndex(
                path: f.sourceRoot.appendingPathComponent("index/items.sqlite").path, create: false)
            defer { index.close() }
            let row = try XCTUnwrap(index.retainedAuthorityObject(id: f.base.revisionID))
            let c = PeerIntakeCoordinator(root: f.sourceRoot, ownerUID: tractanda_uid(), storeID: f.storeID)
            try c.withOperation {
                _ = try c.bytes(row)
                withUnsafeCurrentTask { $0?.cancel() }
                XCTAssertNil(c.progress)
                XCTAssertThrowsError(try c.bytes(row)) { XCTAssertTrue($0 is CancellationError) }
            }
            return c.verifiedOriginalCacheForTesting.entries == 0
        }
        let cleared = try await task.value
        XCTAssertTrue(cleared)
    }
    func testBootstrapRawReuseDoesNotCacheCurrentConfigurationOrAdmissionDecision() throws {
        let f = try Fixture()
        try f.bootstrap()
        let c = PeerIntakeCoordinator(root: f.receiverRoot, ownerUID: tractanda_uid(), storeID: f.storeID)
        let index = try ItemIndex(
            path: f.receiverRoot.appendingPathComponent("index/items.sqlite").path, create: false)
        defer { index.close() }
        let pin = try XCTUnwrap(c.configuration()?.bootstrap)
        let row = try XCTUnwrap(index.retainedAuthorityObject(id: pin.recordID))
        let observedPath = row.path
        let originals = Reads()
        let configuration = Reads()
        try DocumentContentFiles.observeReadsForTesting(
            root: f.receiverRoot,
            observation: { path, bytes in
                if path.joined(separator: "/") == observedPath { originals.add(bytes) }
                if path.first == ".peer-configuration" { configuration.add(bytes) }
            },
            body: {
                try c.withOperation {
                    let first = try XCTUnwrap(c.originAdmission(f.origin, index: index))
                    XCTAssertEqual(try c.originAdmission(f.origin, index: index), first)
                    XCTAssertEqual(originals.bytes, row.descriptor.length)
                    XCTAssertGreaterThan(configuration.bytes, 0)
                    let current = f.receiverRoot.appendingPathComponent(".peer-configuration")
                    let held = f.directory.appendingPathComponent("held-configuration")
                    try FileManager.default.moveItem(at: current, to: held)
                    defer { try? FileManager.default.moveItem(at: held, to: current) }
                    XCTAssertNil(
                        try c.originAdmission(f.origin, index: index),
                        "Current configuration must be consulted again")
                }
            })
        try f.capacity()
    }
    func testPayloadKindsAndEmptyMetadataKeepExistingLoaderSemantics() throws {
        try withOriginal { f, _, _, original in
            let cache = PeerVerifiedOriginalCache(
                root: f.sourceRoot, ownerUID: tractanda_uid(), maximumBytes: 1024)
            for kind in [PeerPackage.Kind.attachment, .document, .index, .authority] {
                for bytes in [Data(), Data([1])] where kind != .authority || bytes.isEmpty {
                    let row = AuthorityStore.RetainedObject(
                        descriptor: .init(
                            kind: kind, id: original.descriptor.id, length: bytes.count,
                            sha256: AuthorityRecordCodec.sha256(bytes)),
                        path: "reader-specific-path", packageID: original.packageID, peerID: original.peerID,
                        configurationDigest: original.configurationDigest,
                        permittedOrigin: original.permittedOrigin)
                    var calls = 0
                    for _ in 0..<2 {
                        XCTAssertEqual(
                            try cache.read(row) {
                                calls += 1
                                return bytes
                            }, bytes)
                    }
                    XCTAssertEqual(calls, 2, "Nonmetadata and zero-length readers must remain authoritative")
                    XCTAssertEqual(cache.entryCount, 0)
                }
            }
        }
    }
    func testWrongOwnerCannotSeedVerifiedBytes() throws {
        try withOriginal { f, c, _, row in
            let cache = PeerVerifiedOriginalCache(
                root: f.sourceRoot, ownerUID: tractanda_uid() + 1, maximumBytes: row.descriptor.length)
            var loaded = false
            XCTAssertThrowsError(
                try cache.read(row) {
                    loaded = true
                    return try c.bytes(row)
                })
            XCTAssertFalse(loaded)
            XCTAssertEqual(cache.residentBytes, 0)
        }
    }
}
