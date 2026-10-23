import CTractandaPlatform
import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class PeerLocalPackageArchiveTests: XCTestCase {
    private typealias Archive = PeerLocalPackageArchive
    private func id(_ n: Int) -> String { String(format: "%08x-0000-1000-8000-000000000001", n) }
    private let identity = String(repeating: "a", count: 64)
    private func object(_ n: Int, digest: String? = nil) -> PeerPackage.Object {
        .init(
            kind: .authority, id: id(n + 1000), length: 1, sha256: digest ?? String(repeating: "b", count: 64)
        )
    }
    private final class Fixture {
        let directory: URL
        let root: URL
        init() throws {
            // All actual fixtures remain tiny; never lower the genuine 10 GiB reserve.
            try AttachmentFixtureCapacity.requireFree()
            directory = try GuardedFixtureDirectory.create(
                prefix: "peer-local-package-", source: #filePath, test: #function)
            root = directory.appendingPathComponent("archive")
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        func archive(maximum: UInt64 = 24 * 1024 * 1024, progress: (() throws -> Void)? = nil) throws
            -> Archive
        {
            try .init(root: root, limits: .init(maximumStoredBytes: maximum), progress: progress)
        }
        func remove(file: StaticString = #filePath, line: UInt = #line) {
            if let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) {
                for case let url as URL in entries {
                    var s = stat()
                    if lstat(url.path, &s) == 0, s.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) {
                        _ = chmod(url.path, 0o600)
                    }
                }
            }
            XCTAssertNoThrow(try FileManager.default.removeItem(at: directory), file: file, line: line)
        }
    }
    private func build(_ archive: Archive, count: Int, input: String? = nil) throws -> PeerPackage.Manifest {
        var ordinal = 0
        return try archive.build(storeID: id(1), packageID: id(2), inputIdentity: input ?? identity) {
            guard ordinal < count else { return nil }
            defer { ordinal += 1 }
            return object(ordinal)
        }
    }
    private func countPages(_ archive: Archive, _ manifest: PeerPackage.Manifest) throws -> Int {
        var count = 0
        try archive.forEachIndexObject(manifest) { descriptor, bytes in
            XCTAssertEqual(descriptor.length, bytes.count)
            XCTAssertEqual(descriptor.sha256, AuthorityRecordCodec.sha256(bytes))
            XCTAssertLessThanOrEqual(bytes.count, PeerPackage.maximumPageBytes)
            let value = try PeerPackage.decode(PeerPackage.Page.self, bytes)
            try value.validate()
            count += 1
        }
        return count
    }

    func testTwoLeavesAndTreeTailUseExistingPageCodecAndRootLast() throws {
        let f = try Fixture()
        defer { f.remove() }
        var completed = false
        let archive = try f.archive {
            if !completed {
                XCTAssertFalse(
                    FileManager.default.fileExists(atPath: f.root.appendingPathComponent("root.json").path))
            }
        }
        let manifest = try build(archive, count: 257)
        completed = true
        var widths: [(Int, Int)] = []
        var ids: [String] = []
        try archive.forEachIndexObject(manifest) { descriptor, bytes in
            let page = try PeerPackage.decode(PeerPackage.Page.self, bytes)
            widths.append((page.objects.count, page.children.count))
            ids.append(descriptor.id)
            XCTAssertNotNil(UUID(uuidString: descriptor.id)?.version1Components)
        }
        XCTAssertEqual(widths.map(\.0), [256, 1, 0])
        XCTAssertEqual(widths.map(\.1), [0, 0, 2])
        XCTAssertEqual(ids.last, manifest.root.id)
        XCTAssertEqual(Set(ids).count, 3)
        let root = f.root.appendingPathComponent("root.json")
        XCTAssertEqual(try FileMetadata.read(at: root).mode & 0o777, 0o400)
        XCTAssertEqual(try build(archive, count: 257), manifest)
    }

    func testInvalidFinalDescriptorNeverPublishesRootAndExactPrefixCanResume() throws {
        let f = try Fixture()
        defer { f.remove() }
        let archive = try f.archive()
        var ordinal = 0
        XCTAssertThrowsError(
            try archive.build(storeID: id(1), packageID: id(2), inputIdentity: identity) {
                defer { ordinal += 1 }
                if ordinal < 257 { return object(ordinal) }
                return PeerPackage.Object(kind: .authority, id: id(2000), length: 0, sha256: identity)
            })
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: f.root.appendingPathComponent("root.json").path))
        // The previous attempt durably emitted one complete leaf before rejecting its final input.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: f.root.appendingPathComponent("levels/0/0/0.page").path))
        let manifest = try build(archive, count: 257)
        XCTAssertEqual(try countPages(archive, manifest), 3)
    }

    func testInterruptedPartialLeafWitnessRejectsAlteredBytesAndShortenedPrefix() throws {
        let f = try Fixture()
        defer { f.remove() }
        let archive = try f.archive()
        var ordinal = 0
        XCTAssertThrowsError(
            try archive.build(storeID: id(1), packageID: id(2), inputIdentity: identity) {
                guard ordinal < 3 else { throw CancellationError() }
                defer { ordinal += 1 }
                return object(ordinal)
            })
        var changed = false
        XCTAssertThrowsError(
            try archive.build(storeID: id(1), packageID: id(2), inputIdentity: identity) {
                guard !changed else { return nil }
                changed = true
                return object(0, digest: String(repeating: "c", count: 64))
            })
        XCTAssertThrowsError(try build(archive, count: 2))
        let manifest = try build(archive, count: 3)
        XCTAssertEqual(try countPages(archive, manifest), 1)
    }

    func testCompletedRootRejectsExtendedChangedAndDifferentSourceInputWithoutDamage() throws {
        let f = try Fixture()
        defer { f.remove() }
        let archive = try f.archive()
        let manifest = try build(archive, count: 2)
        let root = f.root.appendingPathComponent("root.json")
        let before = try FileMetadata.read(at: root)
        XCTAssertThrowsError(try build(archive, count: 3))
        XCTAssertThrowsError(try build(archive, count: 1))
        XCTAssertThrowsError(try build(archive, count: 2, input: String(repeating: "d", count: 64)))
        var emitted = false
        XCTAssertThrowsError(
            try archive.build(storeID: id(3), packageID: id(2), inputIdentity: identity) {
                guard !emitted else { return nil }
                emitted = true
                return object(0)
            })
        var wrong = manifest
        wrong = .init(packageID: id(4), storeID: wrong.storeID, root: wrong.root)
        var calls = 0
        XCTAssertThrowsError(try archive.forEachIndexObject(wrong) { _, _ in calls += 1 })
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(try FileMetadata.read(at: root), before)
        XCTAssertEqual(try countPages(archive, manifest), 1)
        let reservation = f.root.appendingPathComponent("reservation.json")
        let originalReservation = try Data(contentsOf: reservation)
        var fields = try JSON.decode([String: String].self, originalReservation)
        fields["inputIdentity"] = String(repeating: "e", count: 64)
        XCTAssertEqual(chmod(reservation.path, 0o600), 0)
        try JSON.encode(fields).write(to: reservation)
        XCTAssertEqual(chmod(reservation.path, 0o400), 0)
        calls = 0
        XCTAssertThrowsError(try archive.forEachIndexObject(manifest) { _, _ in calls += 1 })
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(chmod(reservation.path, 0o600), 0)
        try originalReservation.write(to: reservation)
        XCTAssertEqual(chmod(reservation.path, 0o400), 0)
        XCTAssertEqual(try countPages(archive, manifest), 1)
    }

    func testEmptyDuplicateDescendingAndIndexInputsFailClosed() throws {
        let f = try Fixture()
        defer { f.remove() }
        let archive = try f.archive()
        XCTAssertThrowsError(try build(archive, count: 0))
        for sequence in [[object(1), object(1)], [object(1), object(0)]] {
            var iterator = sequence.makeIterator()
            XCTAssertThrowsError(
                try archive.build(storeID: id(1), packageID: id(2), inputIdentity: identity) {
                    iterator.next()
                })
        }
        // A fresh private archive isolates descriptor validation from earlier immutable prefix evidence.
        let g = try Fixture()
        defer { g.remove() }
        let other = try g.archive()
        var emitted = false
        XCTAssertThrowsError(
            try other.build(storeID: id(1), packageID: id(2), inputIdentity: identity) {
                guard !emitted else { return nil }
                emitted = true
                return .init(kind: .index, id: id(1000), length: 1, sha256: identity)
            })
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: g.root.appendingPathComponent("root.json").path))
    }

    func testFreshLeaseAccountingRejectsExistingUnknownDataAndPreservesIt() throws {
        let f = try Fixture()
        defer { f.remove() }
        let archive = try f.archive(maximum: 32 * 1024)
        let unknown = f.root.appendingPathComponent("caller-data")
        let bytes = Data(repeating: 7, count: 32 * 1024)
        try bytes.write(to: unknown)
        XCTAssertEqual(chmod(unknown.path, 0o600), 0)
        XCTAssertThrowsError(try build(archive, count: 1))
        XCTAssertEqual(try Data(contentsOf: unknown), bytes)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: f.root.appendingPathComponent("root.json").path))
    }

    func testRealFilesystemReserveAndCountWorkDepthBudgetsFailClosed() throws {
        let f = try Fixture()
        defer { f.remove() }
        XCTAssertThrowsError(
            try Archive(
                root: f.root, limits: .init(maximumStoredBytes: 1024 * 1024, minimumFreeBytes: Int64.max)))
        let countArchive = try Archive(
            root: f.root, limits: .init(maximumStoredBytes: 1024 * 1024, maximumObjects: 1))
        XCTAssertThrowsError(try build(countArchive, count: 2))
        let g = try Fixture()
        defer { g.remove() }
        let workArchive = try Archive(
            root: g.root, limits: .init(maximumStoredBytes: 1024 * 1024, maximumWork: 1))
        XCTAssertThrowsError(try build(workArchive, count: 1))
        let h = try Fixture()
        defer { h.remove() }
        let depthArchive = try Archive(
            root: h.root, limits: .init(maximumStoredBytes: 24 * 1024 * 1024, maximumDepth: 1))
        XCTAssertThrowsError(try build(depthArchive, count: 257))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: h.root.appendingPathComponent("root.json").path))
        let physical = try Fixture()
        defer { physical.remove() }
        let physicalArchive = try Archive(
            root: physical.root, limits: .init(maximumStoredBytes: 1024 * 1024, maximumObjects: 2))
        // Two originals fit the input count, but their generated root is a third physical object.
        XCTAssertThrowsError(try build(physicalArchive, count: 2))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: physical.root.appendingPathComponent("root.json").path))
    }

    func testProgressCancellationRetainsPrefixAndCanRetry() throws {
        let f = try Fixture()
        defer { f.remove() }
        var calls = 0
        let archive = try f.archive {
            calls += 1
            if calls == 4 { throw CancellationError() }
        }
        XCTAssertThrowsError(try build(archive, count: 257))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: f.root.appendingPathComponent("root.json").path))
        let manifest = try build(f.archive(), count: 257)
        XCTAssertEqual(try countPages(f.archive(), manifest), 3)
    }

    func testActualTaskCancellationFailsBeforePublishingRoot() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let root = f.root
        let storeID = id(1)
        let packageID = id(2)
        let input = identity
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let archive = try Archive(root: root, limits: .init(maximumStoredBytes: 1024 * 1024))
            return try archive.build(storeID: storeID, packageID: packageID, inputIdentity: input) { nil }
        }
        do {
            _ = try await task.value
            XCTFail("A cancelled task must not publish a root")
        } catch is CancellationError {
            // The real Task.checkCancellation path, without a test-only filesystem bypass.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("root.json").path))
    }

    func testLeaseReplacementDuringProgressFailsBeforeRootAndPreservesUnknownReplacement() throws {
        let f = try Fixture()
        defer { f.remove() }
        var replaced = false
        let lease = f.root.appendingPathComponent(".package.lock")
        let retained = f.root.appendingPathComponent("retained-original-lock")
        let archive = try f.archive {
            guard !replaced else { return }
            replaced = true
            try FileManager.default.moveItem(at: lease, to: retained)
            try Data().write(to: lease)
            XCTAssertEqual(chmod(lease.path, 0o600), 0)
        }
        XCTAssertThrowsError(try build(archive, count: 1))
        XCTAssertTrue(replaced)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: f.root.appendingPathComponent("root.json").path))
    }

    func testCallbackCannotSubstituteLaterPageAndDescriptorOutsideCommittedRoot() throws {
        let f = try Fixture()
        defer { f.remove() }
        let archive = try f.archive()
        let manifest = try build(archive, count: 257)
        let laterPage = f.root.appendingPathComponent("levels/0/0/1.page")
        let laterDescriptor = f.root.appendingPathComponent("levels/0/0/1.descriptor")
        let oldPage = try Data(contentsOf: laterPage)
        let oldDescriptor = try Data(contentsOf: laterDescriptor)
        let originalPage = try PeerPackage.decode(PeerPackage.Page.self, oldPage)
        let originalDescriptor = try PeerPackage.decode(PeerPackage.Object.self, oldDescriptor)
        let changedObject = PeerPackage.Object(
            kind: originalPage.objects[0].kind, id: originalPage.objects[0].id,
            length: originalPage.objects[0].length, sha256: String(repeating: "f", count: 64))
        let changedPage = try JSON.encode(PeerPackage.Page(objects: [changedObject], children: []))
        let changedDescriptor = try JSON.encode(
            PeerPackage.Object(
                kind: .index, id: originalDescriptor.id, length: changedPage.count,
                sha256: AuthorityRecordCodec.sha256(changedPage)))
        // Both substituted files satisfy real private-artifact custody and the unchanged codec.
        try PeerPackage.decode(PeerPackage.Page.self, changedPage).validate()
        try PeerPackage.decode(PeerPackage.Object.self, changedDescriptor).validate()
        func replace(_ url: URL, _ bytes: Data) throws {
            XCTAssertEqual(chmod(url.path, 0o600), 0)
            try bytes.write(to: url)
            XCTAssertEqual(chmod(url.path, 0o400), 0)
        }
        var calls = 0
        XCTAssertThrowsError(
            try archive.forEachIndexObject(manifest) { descriptor, _ in
                calls += 1
                XCTAssertNotEqual(descriptor.id, manifest.root.id)
                if calls == 1 {
                    try replace(laterPage, changedPage)
                    try replace(laterDescriptor, changedDescriptor)
                }
            })
        XCTAssertEqual(calls, 1, "The substituted leaf and root must never reach the caller")
        try replace(laterPage, oldPage)
        try replace(laterDescriptor, oldDescriptor)
        XCTAssertEqual(try countPages(archive, manifest), 3)
        XCTAssertEqual(try build(archive, count: 257), manifest)

        let reservation = f.root.appendingPathComponent("reservation.json")
        let originalReservation = try Data(contentsOf: reservation)
        var fields = try JSON.decode([String: String].self, originalReservation)
        fields["inputIdentity"] = String(repeating: "e", count: 64)
        calls = 0
        XCTAssertThrowsError(
            try archive.forEachIndexObject(manifest) { _, _ in
                calls += 1
                try replace(reservation, JSON.encode(fields))
            })
        XCTAssertEqual(calls, 1, "Source binding replacement must prevent iterator completion")
        try replace(reservation, originalReservation)
        XCTAssertEqual(try countPages(archive, manifest), 3)
    }

    func testRootReplacementSymlinkAndHardlinkAreRejected() throws {
        let f = try Fixture()
        defer { f.remove() }
        let archive = try f.archive()
        let oldRoot = f.directory.appendingPathComponent("old-root")
        try FileManager.default.moveItem(at: f.root, to: oldRoot)
        try FileManager.default.createDirectory(
            at: f.root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        XCTAssertThrowsError(try build(archive, count: 1))
        let g = try Fixture()
        defer { g.remove() }
        let other = try g.archive()
        let manifest = try build(other, count: 1)
        let descriptor = g.root.appendingPathComponent("levels/0/0/0.descriptor")
        let linkURL = g.root.appendingPathComponent("unknown-hardlink")
        XCTAssertEqual(link(descriptor.path, linkURL.path), 0)
        XCTAssertThrowsError(
            try other.forEachIndexObject(manifest) { _, _ in XCTFail("Unsafe inventory must yield nothing") })
        XCTAssertEqual(unlink(linkURL.path), 0)
        let input = g.root.appendingPathComponent("inputs/0/0.json")
        XCTAssertEqual(unlink(input.path), 0)
        XCTAssertEqual(symlink(descriptor.path, input.path), 0)
        XCTAssertThrowsError(
            try other.forEachIndexObject(manifest) { _, _ in XCTFail("Unsafe input must yield nothing") })
    }
}
