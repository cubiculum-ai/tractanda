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
