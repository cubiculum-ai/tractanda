import Foundation
import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

private func peerFixtureUUID() throws -> String {
    try UUID.makeVersion1().uuidString.lowercased()
}

final class PeerIntakeJournalTests: XCTestCase {
    private enum InjectedCrash: Error { case boundary }

    private struct StagedObject {
        let descriptor: PeerPackage.Object
        let bytes: Data
    }

    private final class Fixture {
        let root: URL
        let ownerUID: UInt32
        let context: PeerPackage.Context
        let manifest: PeerPackage.Manifest
        let manifestBytes: Data
        let stagedObjects: [StagedObject]
        let limits: PeerPackage.Limits
        var journal: PeerIntakeJournal

        init(itemBytes: [Data], limits: PeerPackage.Limits = .init()) throws {
            try AttachmentFixtureCapacity.requireFree()
            self.limits = limits
            ownerUID = UInt32(getuid())
            let storeID = try peerFixtureUUID()
            let packageID = try peerFixtureUUID()
            let originID = try peerFixtureUUID()
            context = try PeerPackage.Context(
                peerID: "fixture-peer", storeID: storeID,
                configurationDigest: AuthorityRecordCodec.sha256(Data("fixture-configuration".utf8)),
                permittedOrigins: [originID])

            let itemObjects = try itemBytes.map { bytes in
                try Self.object(kind: .item, id: peerFixtureUUID(), bytes: bytes)
            }
            var pageObjects: [StagedObject] = []
            var childDescriptors: [PeerPackage.Object] = []
            for start in stride(from: 0, to: itemObjects.count, by: 256) {
                let page = PeerPackage.Page(
                    objects: Array(itemObjects[start..<min(start + 256, itemObjects.count)]), children: [])
                let bytes = try JSON.encode(page)
                let descriptor = try Self.object(kind: .index, id: peerFixtureUUID(), bytes: bytes)
                pageObjects.append(StagedObject(descriptor: descriptor, bytes: bytes))
                childDescriptors.append(descriptor)
            }
            let root: PeerPackage.Object
            if childDescriptors.count == 1 {
                root = childDescriptors[0]
            } else {
                let page = PeerPackage.Page(objects: [], children: childDescriptors)
                let bytes = try JSON.encode(page)
                root = try Self.object(kind: .index, id: peerFixtureUUID(), bytes: bytes)
                pageObjects.append(StagedObject(descriptor: root, bytes: bytes))
            }
            manifest = PeerPackage.Manifest(packageID: packageID, storeID: storeID, root: root)
            manifestBytes = try JSON.encode(manifest)
            stagedObjects =
                pageObjects
                + zip(itemObjects, itemBytes).map {
                    StagedObject(descriptor: $0.0, bytes: $0.1)
                }
            let estimate = UInt64(
                manifestBytes.count
                    + stagedObjects.reduce(0) {
                        $0 + $1.bytes.count + (try! JSON.encode($1.descriptor)).count + 32 * 1024
                    })
            guard estimate <= AttachmentFixtureCapacity.fixtureCapBytes else {
                throw TractandaError("resourceLimit", "Peer journal test fixture exceeds its cap.")
            }
            let rootURL = (try GuardedFixtureDirectory.parent())
                .appendingPathComponent("tractanda-peer-intake-" + (try peerFixtureUUID()), isDirectory: true)
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(
                at: rootURL, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            self.root = rootURL
            journal = PeerIntakeJournal(root: rootURL, ownerUID: ownerUID, limits: limits)
            try checkCapacity()
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func makeJournal() -> PeerIntakeJournal {
            PeerIntakeJournal(root: root, ownerUID: ownerUID, limits: limits)
        }

        func guarded<T>(_ write: () throws -> T) throws -> T {
            try checkCapacity()
            do {
                let result = try write()
                try checkCapacity()
                return result
            } catch {
                try checkCapacity()
                throw error
            }
        }

        func begin() throws -> PeerPackage.Status {
            try guarded { try journal.begin(context: context, manifestBytes: manifestBytes) }
        }

        func append(_ object: StagedObject, offset: Int = 0, bytes: Data? = nil) throws -> PeerPackage.Status
        {
            let part =
                bytes
                ?? object.bytes.subdata(
                    in: offset..<min(offset + PeerPackage.maximumChunkBytes, object.bytes.count))
            return try guarded {
                try journal.append(
                    context: context, packageID: manifest.packageID, object: object.descriptor,
                    offset: offset, bytes: part)
            }
        }

        func stageAll() throws {
            _ = try begin()
            for object in stagedObjects { _ = try append(object) }
            try checkCapacity()
        }

        func publication(arrivalMinute: String = "2026/10/14/12/34") -> PeerIntakeJournal.Publication {
            PeerIntakeJournal.Publication(
                packageID: manifest.packageID,
                manifestDigest: AuthorityRecordCodec.sha256(manifestBytes), context: context,
                contextToken: context.configurationDigest, arrivalMinute: arrivalMinute)
        }

        func checkCapacity() throws {
            try AttachmentFixtureCapacity.requireFree()
            guard
                let enumerator = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
            else {
                throw TractandaError("resourceLimit", "Cannot inspect peer test fixture size.")
            }
            var size: UInt64 = 0
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if values.isRegularFile == true, let fileSize = values.fileSize, fileSize > 0 {
                    size += UInt64(fileSize)
                    guard size <= AttachmentFixtureCapacity.fixtureCapBytes else {
                        throw TractandaError("resourceLimit", "Peer journal fixture exceeded its cap.")
                    }
                }
            }
        }

        private static func object(kind: PeerPackage.Kind, id: String, bytes: Data) throws
            -> PeerPackage.Object
        {
            PeerPackage.Object(
                kind: kind, id: id, length: bytes.count, sha256: AuthorityRecordCodec.sha256(bytes))
        }
    }

    func testBeginAndChunkRetriesAreExactAndCollisionsReject() throws {
        let fixture = try Fixture(itemBytes: [Data("small fixture object".utf8)])
        let begin = try fixture.begin()
        XCTAssertEqual(try fixture.begin(), begin)
        let root = try XCTUnwrap(fixture.stagedObjects.first)
        let first = try fixture.append(root)
        XCTAssertEqual(try fixture.append(root), first)
        XCTAssertThrowsError(try fixture.append(root, bytes: Data(repeating: 0x7f, count: root.bytes.count)))
        {
            XCTAssertEqual(($0 as? TractandaError)?.code, "peerObjectCollision")
        }
        let changedContext = try PeerPackage.Context(
            peerID: fixture.context.peerID, storeID: fixture.context.storeID,
            configurationDigest: fixture.context.configurationDigest,
            permittedOrigins: [try peerFixtureUUID()])
        XCTAssertThrowsError(
            try fixture.journal.begin(
                context: changedContext, manifestBytes: fixture.manifestBytes)
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "peerObjectCollision")
        }
    }
    func testKnownPackageTransitionsKeepAggregateWorkLinearBeyondStatusCacheCapacity() throws {
        let fixture = try Fixture(itemBytes: [Data("tiny".utf8)])
        let override = ProcessInfo.processInfo.environment["TRACTANDA_QUOTA_MEASUREMENT_COUNT"]
        let count = override.flatMap(Int.init) ?? 272
        guard override == nil || [128, 256, 512, 1024].contains(count) else {
            throw TractandaError("invalidArguments", "Unsupported bounded metadata measurement size.")
        }
        let started = ProcessInfo.processInfo.systemUptime
        var guardSeconds = 0.0
        func capacity() throws {
            let start = ProcessInfo.processInfo.systemUptime
            try fixture.checkCapacity()
            guardSeconds += ProcessInfo.processInfo.systemUptime - start
        }
        func output(_ phase: String, completed: Int) throws {
            guard let path = ProcessInfo.processInfo.environment["TRACTANDA_SCALING_RESULT"] else { return }
            let value: [String: Any] = [
                "profile": "tractanda.scaling-measurement.v1", "kind": "quota",
                "phase": phase, "pid": Int(getpid()), "fixtureRoot": fixture.root.path,
                "count": count, "completed": completed,
                "wallSeconds": ProcessInfo.processInfo.systemUptime - started, "guardSeconds": guardSeconds,
                "inventoryScans": fixture.journal.stagingInventoryScansForTesting,
                "statusScans": fixture.journal.stagingStatusScansForTesting,
                "beginDecodes": fixture.journal.beginDecodesForTesting,
            ]
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(
                to: URL(fileURLWithPath: path), options: .atomic)
        }
        try output("quota-staging", completed: 0)
        guard UInt64(count * 32 * 1024) <= AttachmentFixtureCapacity.fixtureCapBytes else {
            throw TractandaError("resourceLimit", "Metadata fixture estimate exceeds its cap.")
        }
        var packages: [String] = []
        var expected: UInt64 = 0
        for offset in 0..<count {
            if offset % 16 == 0 { try capacity() }
            if offset % 64 == 0 { try output("quota-staging", completed: offset) }
            let id = try peerFixtureUUID()
            let manifest = PeerPackage.Manifest(
                packageID: id, storeID: fixture.context.storeID, root: fixture.manifest.root)
            let manifestBytes = try JSON.encode(manifest)
            _ = try fixture.journal.begin(context: fixture.context, manifestBytes: manifestBytes)
            let publication = PeerIntakeJournal.Publication(
                packageID: id, manifestDigest: AuthorityRecordCodec.sha256(manifestBytes),
                context: fixture.context, contextToken: fixture.context.configurationDigest,
                arrivalMinute: "2026/10/20/12/34")
            try fixture.journal.prepare(publication)
            try fixture.journal.seal(id)
            expected += UInt64(
                try JSON.encode(
                    PeerIntakeJournal.Begin(
                        manifest: manifest, context: fixture.context)
                ).count + 2 * JSON.encode(publication).count)
            XCTAssertEqual(try fixture.journal.stagedBytesForTesting(), expected)
            packages.append(id)
        }
        XCTAssertEqual(
            fixture.journal.stagingInventoryScansForTesting, 1,
            "Known successful mutations must not rescan every previous package")
        XCTAssertLessThanOrEqual(fixture.journal.stagingStatusScansForTesting, count * 4)
        XCTAssertLessThanOrEqual(
            fixture.journal.beginDecodesForTesting, count * 80,
            "Immutable/authentication reads remain fresh but bounded per touched package")
        XCTAssertEqual(
            try fixture.makeJournal().stagedBytesForTesting(), expected,
            "Restart reconstructs the same actual retained charge")
        for (offset, id) in packages.enumerated() {
            if offset % 16 == 0 { try capacity() }
            if offset % 64 == 0 { try output("quota-applying", completed: offset) }
            try fixture.journal.applied(id)
        }
        XCTAssertEqual(try fixture.journal.stagedBytesForTesting(), 0)
        XCTAssertEqual(fixture.journal.stagingInventoryScansForTesting, 1)
        XCTAssertEqual(try fixture.makeJournal().stagedBytesForTesting(), 0)
        print(
            "IntakeQuotaOperationEvidence packages=\(count) inventoryScans="
                + "\(fixture.journal.stagingInventoryScansForTesting) statusScans="
                + "\(fixture.journal.stagingStatusScansForTesting) beginDecodes=\(fixture.journal.beginDecodesForTesting)"
        )
        try capacity()
        try output("complete", completed: count)
    }
    func testFailedPhaseMutationInvalidatesAggregateAndQuotaRefusalPreservesFiles() throws {
        let began = try Fixture(itemBytes: [Data("failed begin".utf8)])
        began.journal.afterBoundaryForTesting = {
            if $0 == .began { throw InjectedCrash.boundary }
        }
        XCTAssertThrowsError(try began.begin())
        XCTAssertEqual(
            try began.journal.stagedBytesForTesting(), try began.makeJournal().stagedBytesForTesting())
        XCTAssertEqual(
            began.journal.stagingInventoryScansForTesting, 2,
            "An uncertain Begin must reconstruct actual files before reusing quota")
        let fixture = try Fixture(itemBytes: [Data("failure accounting".utf8)])
        try fixture.stageAll()
        _ = try fixture.journal.stagedBytesForTesting()
        let scans = fixture.journal.stagingInventoryScansForTesting
        let publication = fixture.publication()
        fixture.journal.afterBoundaryForTesting = {
            if $0 == .prepared { throw InjectedCrash.boundary }
        }
        XCTAssertThrowsError(try fixture.journal.prepare(publication))
        let retained = try fixture.journal.stagedBytesForTesting()
        XCTAssertEqual(fixture.journal.stagingInventoryScansForTesting, scans + 1)
        XCTAssertEqual(retained, try fixture.makeJournal().stagedBytesForTesting())
        fixture.journal.afterBoundaryForTesting = nil
        try fixture.journal.prepare(publication)
        try fixture.journal.seal(publication.packageID)
        fixture.journal.afterBoundaryForTesting = {
            if $0 == .applied { throw InjectedCrash.boundary }
        }
        XCTAssertThrowsError(try fixture.journal.applied(publication.packageID))
        XCTAssertEqual(try fixture.journal.stagedBytesForTesting(), 0)
        XCTAssertEqual(try fixture.makeJournal().stagedBytesForTesting(), 0)

        let limited = try Fixture(itemBytes: [Data("quota refusal".utf8)])
        try limited.stageAll()
        let before = try limited.journal.stagedBytesForTesting()
        let phase = limited.publication()
        var limits = limited.limits
        limits.maximumStagedBytes = before + UInt64(try JSON.encode(phase).count) - 1
        let journal = PeerIntakeJournal(root: limited.root, ownerUID: limited.ownerUID, limits: limits)
        XCTAssertEqual(try journal.stagedBytesForTesting(), before)
        XCTAssertThrowsError(try journal.prepare(phase)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
        }
        XCTAssertEqual(try journal.stagedBytesForTesting(), before)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: limited.root.appendingPathComponent(
                    "authority/intake/\(phase.packageID)/prepared.json"
                ).path))
        limits = limited.limits
        limits.maximumObjects = 2  // Existing package has one index and one item stage.
        let single = PeerIntakeJournal(root: limited.root, ownerUID: limited.ownerUID, limits: limits)
        _ = try single.stagedBytesForTesting()
        let second = PeerPackage.Manifest(
            packageID: try peerFixtureUUID(), storeID: limited.context.storeID,
            root: limited.manifest.root)
        _ = try single.begin(context: limited.context, manifestBytes: JSON.encode(second))
        let extraID = try peerFixtureUUID()
        let extra = PeerPackage.Manifest(
            packageID: extraID, storeID: limited.context.storeID,
            root: limited.manifest.root)
        XCTAssertThrowsError(try single.begin(context: limited.context, manifestBytes: JSON.encode(extra))) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: limited.root.appendingPathComponent(
                    "authority/intake/\(extraID)"
                ).path))
        try limited.checkCapacity()
    }

    func testResumeAfterNewJournalInstanceAtFramedChunkBoundary() throws {
        let payload = Data(repeating: 0x51, count: PeerPackage.maximumChunkBytes + 17)
        let fixture = try Fixture(itemBytes: [payload])
        _ = try fixture.begin()
        let item = try XCTUnwrap(fixture.stagedObjects.last)
        let firstChunk = payload.prefix(PeerPackage.maximumChunkBytes)
        _ = try fixture.append(item, offset: 0, bytes: Data(firstChunk))

        let resumed = fixture.makeJournal()
        let tail = Data(payload.suffix(17))
        try fixture.checkCapacity()
        _ = try resumed.append(
            context: fixture.context, packageID: fixture.manifest.packageID,
            object: item.descriptor, offset: PeerPackage.maximumChunkBytes, bytes: tail)
        try fixture.checkCapacity()
        XCTAssertEqual(
            try resumed.object(item.descriptor, packageID: fixture.manifest.packageID), payload)
        XCTAssertEqual(
            try resumed.append(
                context: fixture.context, packageID: fixture.manifest.packageID,
                object: item.descriptor, offset: PeerPackage.maximumChunkBytes, bytes: tail
            ).receivedBytes,
            try resumed.status(fixture.manifest.packageID).receivedBytes)
        XCTAssertThrowsError(
            try resumed.append(
                context: fixture.context, packageID: fixture.manifest.packageID,
                object: item.descriptor, offset: PeerPackage.maximumChunkBytes,
                bytes: Data(repeating: 0x52, count: 17))
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "peerObjectCollision")
        }
    }

    func testHierarchicalWalkVisitsMoreThan256EntriesAcrossPages() throws {
        let payloads = (0..<257).map { Data([UInt8($0 & 0xff)]) }
        var limits = PeerPackage.Limits()
        limits.maximumStagedBytes = 16 * 1024 * 1024
        limits.maximumObjects = 512
        limits.maximumWork = 2048
        limits.maximumDepth = 8
        let fixture = try Fixture(itemBytes: payloads, limits: limits)
        try fixture.stageAll()
        var visited: [String: Data] = [:]
        try fixture.journal.walk(fixture.manifest.packageID) { object, bytes in
            XCTAssertEqual(object.kind, .item)
            visited[object.id] = try XCTUnwrap(bytes)
        }
        XCTAssertEqual(visited.count, 257)
        XCTAssertEqual(Set(visited.values), Set(payloads))
    }

    func testMissingRootPageIsExplicitAndTinyStagingLimitDoesNotWriteChunk() throws {
        let missing = try Fixture(itemBytes: [Data("missing page".utf8)])
        _ = try missing.begin()
        XCTAssertThrowsError(try missing.journal.walk(missing.manifest.packageID, visit: { _, _ in })) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "missingDependencies")
        }

        var limits = PeerPackage.Limits()
        limits.maximumStagedBytes = 1024
        let limited = try Fixture(itemBytes: [Data(repeating: 0x33, count: 900)], limits: limits)
        _ = try limited.begin()
        let object = try XCTUnwrap(limited.stagedObjects.last)
        XCTAssertThrowsError(try limited.append(object)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
        }
        XCTAssertNil(
            try limited.journal.files.readIfPresent(
                path: [
                    "authority", "intake", limited.manifest.packageID,
                    "objects", object.descriptor.id, "0",
                ],
                maximumBytes: PeerPackage.maximumChunkBytes))
    }

    func testEveryDurableBoundaryCanRecoverByReopeningAndExactRetry() throws {
        for boundary in [PeerIntakeJournal.Boundary.began, .chunk, .prepared, .sealed, .applied] {
            let fixture = try Fixture(itemBytes: [Data("boundary fixture".utf8)])
            switch boundary {
            case .began:
                fixture.journal.afterBoundaryForTesting = {
                    if $0 == boundary { throw InjectedCrash.boundary }
                }
                XCTAssertThrowsError(try fixture.begin())
                fixture.journal = fixture.makeJournal()
                XCTAssertEqual(try fixture.begin().packageID, fixture.manifest.packageID)
            case .chunk:
                _ = try fixture.begin()
                let object = try XCTUnwrap(fixture.stagedObjects.first)
                fixture.journal.afterBoundaryForTesting = {
                    if $0 == boundary { throw InjectedCrash.boundary }
                }
                XCTAssertThrowsError(try fixture.append(object))
                fixture.journal = fixture.makeJournal()
                XCTAssertEqual(
                    try fixture.append(object).receivedBytes,
                    try fixture.journal.status(fixture.manifest.packageID).receivedBytes)
            case .prepared:
                try fixture.stageAll()
                let record = fixture.publication()
                fixture.journal.afterBoundaryForTesting = {
                    if $0 == boundary { throw InjectedCrash.boundary }
                }
                XCTAssertThrowsError(try fixture.guarded { try fixture.journal.prepare(record) })
                fixture.journal = fixture.makeJournal()
                try fixture.guarded { try fixture.journal.prepare(record) }
                try fixture.guarded { try fixture.journal.seal(record.packageID) }
                XCTAssertNotNil(try fixture.journal.publication(record.packageID))
            case .sealed:
                try fixture.stageAll()
                let record = fixture.publication()
                try fixture.guarded { try fixture.journal.prepare(record) }
                fixture.journal.afterBoundaryForTesting = {
                    if $0 == boundary { throw InjectedCrash.boundary }
                }
                XCTAssertThrowsError(try fixture.guarded { try fixture.journal.seal(record.packageID) })
                fixture.journal = fixture.makeJournal()
                XCTAssertEqual(try fixture.journal.publication(record.packageID), record)
                XCTAssertTrue(try fixture.journal.status(record.packageID).sealed)
                try fixture.guarded { try fixture.journal.seal(record.packageID) }
            case .applied:
                try fixture.stageAll()
                let record = fixture.publication()
                try fixture.guarded { try fixture.journal.prepare(record) }
                try fixture.guarded { try fixture.journal.seal(record.packageID) }
                fixture.journal.afterBoundaryForTesting = {
                    if $0 == boundary { throw InjectedCrash.boundary }
                }
                XCTAssertThrowsError(try fixture.guarded { try fixture.journal.applied(record.packageID) })
                fixture.journal = fixture.makeJournal()
                try fixture.guarded { try fixture.journal.applied(record.packageID) }
                let applied = try XCTUnwrap(
                    fixture.journal.files.readIfPresent(
                        path: ["authority", "intake", record.packageID, "applied.json"],
                        maximumBytes: PeerPackage.maximumPageBytes))
                XCTAssertEqual(try PeerPackage.decode(PeerIntakeJournal.Publication.self, applied), record)
            }
            try fixture.checkCapacity()
        }
    }
}
