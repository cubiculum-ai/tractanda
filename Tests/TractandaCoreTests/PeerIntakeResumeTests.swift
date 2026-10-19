import Foundation
import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class PeerIntakeResumeTests: XCTestCase {
    private struct Staged {
        let descriptor: PeerPackage.Object
        let bytes: Data
    }

    private final class Fixture {
        let root: URL
        let ownerUID = UInt32(getuid())
        let context: PeerPackage.Context
        let manifest: PeerPackage.Manifest
        let manifestBytes: Data
        let items: [Staged]
        let indexes: [Staged]
        let limits: PeerPackage.Limits
        let journal: PeerIntakeJournal
        private let allObjects: [Staged]

        init(itemPayloads: [Data], limits: PeerPackage.Limits = .init()) throws {
            try AttachmentFixtureCapacity.requireFree()
            self.limits = limits
            guard !itemPayloads.isEmpty else {
                throw TractandaError("resourceLimit", "Resume fixture needs at least one object.")
            }
            let storeID = try Self.uuid()
            let packageID = try Self.uuid()
            context = try PeerPackage.Context(
                peerID: "resume-peer", storeID: storeID,
                configurationDigest: AuthorityRecordCodec.sha256(Data("resume-fixture".utf8)),
                permittedOrigins: [try Self.uuid()])
            items = try itemPayloads.map { bytes in
                Staged(descriptor: try Self.descriptor(kind: .item, bytes: bytes), bytes: bytes)
            }
            var pages: [Staged] = []
            for start in stride(from: 0, to: items.count, by: 256) {
                let page = PeerPackage.Page(
                    objects: items[start..<min(start + 256, items.count)].map(\.descriptor), children: [])
                let bytes = try JSON.encode(page)
                pages.append(
                    Staged(descriptor: try Self.descriptor(kind: .index, bytes: bytes), bytes: bytes))
            }
            let rootPage: Staged
            if pages.count == 1 {
                rootPage = pages[0]
                indexes = pages
                allObjects = pages + items
            } else {
                let bytes = try JSON.encode(PeerPackage.Page(objects: [], children: pages.map(\.descriptor)))
                rootPage = Staged(descriptor: try Self.descriptor(kind: .index, bytes: bytes), bytes: bytes)
                indexes = [rootPage] + pages
                allObjects = indexes + items
            }
            manifest = PeerPackage.Manifest(packageID: packageID, storeID: storeID, root: rootPage.descriptor)
            manifestBytes = try JSON.encode(manifest)
            let estimate = UInt64(
                manifestBytes.count
                    + allObjects.reduce(0) {
                        $0 + $1.bytes.count + (try! JSON.encode($1.descriptor)).count + 4096
                    })
            guard estimate <= min(32 * 1024 * 1024, AttachmentFixtureCapacity.fixtureCapBytes) else {
                throw TractandaError("resourceLimit", "Resume fixture estimate exceeds its cap.")
            }
            let rootURL = (try GuardedFixtureDirectory.parent())
                .appendingPathComponent("tractanda-peer-resume-" + (try Self.uuid()), isDirectory: true)
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(
                at: rootURL, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            root = rootURL
            journal = PeerIntakeJournal(root: rootURL, ownerUID: ownerUID, limits: limits)
            try checkCapacity()
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        static func uuid() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }

        static func descriptor(kind: PeerPackage.Kind, bytes: Data) throws -> PeerPackage.Object {
            try PeerPackage.Object(
                kind: kind, id: uuid(), length: bytes.count, sha256: AuthorityRecordCodec.sha256(bytes))
        }

        func makeJournal() -> PeerIntakeJournal {
            PeerIntakeJournal(root: root, ownerUID: ownerUID, limits: limits)
        }

        func begin() throws {
            try checkCapacity()
            _ = try journal.begin(context: context, manifestBytes: manifestBytes)
            try checkCapacity()
        }

        func append(
            _ staged: Staged, offset: Int = 0, bytes: Data? = nil, using target: PeerIntakeJournal? = nil
        )
            throws
        {
            let receiver = target ?? journal
            let payload =
                bytes
                ?? staged.bytes.subdata(
                    in: offset..<min(offset + PeerPackage.maximumChunkBytes, staged.bytes.count))
            try checkCapacity()
            _ = try receiver.append(
                context: context, packageID: manifest.packageID, object: staged.descriptor,
                offset: offset, bytes: payload)
            try checkCapacity()
        }

        func appendWholeIndexes() throws {
            for staged in indexes { try appendWhole(staged) }
        }

        func appendWhole(_ staged: Staged, using target: PeerIntakeJournal? = nil) throws {
            for offset in stride(from: 0, to: staged.bytes.count, by: PeerPackage.maximumChunkBytes) {
                try append(staged, offset: offset, using: target)
            }
        }

        func write(_ bytes: Data, path: [String], maximum: Int) throws {
            try checkCapacity()
            try journal.files.writeImmutable(bytes, path: path, maximumBytes: maximum)
            try checkCapacity()
        }

        func remove(_ path: [String]) throws {
            try checkCapacity()
            try FileManager.default.removeItem(at: root.appendingPathComponent(path.joined(separator: "/")))
            try checkCapacity()
        }

        func checkCapacity() throws {
            try AttachmentFixtureCapacity.requireFree()
            try AttachmentFixtureCapacity.requireFree(at: root)
            guard
                let enumerator = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
            else { throw TractandaError("resourceLimit", "Cannot inspect resume fixture size.") }
            var bytes: UInt64 = 0
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if values.isRegularFile == true, let size = values.fileSize {
                    bytes += UInt64(size)
                    guard bytes <= min(32 * 1024 * 1024, AttachmentFixtureCapacity.fixtureCapBytes) else {
                        throw TractandaError("resourceLimit", "Resume fixture exceeded its cap.")
                    }
                }
            }
        }

        func chunkPath(_ item: Staged, offset: Int, proof: Bool = false) -> [String] {
            [
                "authority", "intake", manifest.packageID, "objects", item.descriptor.id,
                String(offset) + (proof ? ".proof.json" : ""),
            ]
        }

    }

    private func code(
        _ expected: String, file: StaticString = #filePath, line: UInt = #line,
        _ body: () throws -> Void
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(($0 as? TractandaError)?.code, expected, file: file, line: line)
        }
    }

    func testMissingIndexBlocksAndResumesWithExactContextWithoutImpliedAcceptance() throws {
        let f = try Fixture(itemPayloads: [Data("one small item".utf8)])
        try f.begin()
        let waiting = try f.journal.resumePage(context: f.context, packageID: f.manifest.packageID)
        XCTAssertTrue(waiting.blockedOnIndex)
        XCTAssertEqual(waiting.state.phase, .staged)
        XCTAssertFalse(waiting.state.recoveryRequired)
        let missingRoot = try XCTUnwrap(waiting.objects.first)
        XCTAssertEqual(missingRoot.descriptor, f.manifest.root)
        XCTAssertEqual(missingRoot.nextOffset, 0)
        XCTAssertEqual(missingRoot.source, .missing)
        XCTAssertNil(missingRoot.evaluation)
        let cursor = try XCTUnwrap(waiting.nextCursor)

        let root = try XCTUnwrap(f.indexes.first)
        try f.appendWhole(root)
        let resumed = try f.makeJournal().resumePage(
            context: f.context, packageID: f.manifest.packageID, cursor: cursor, limit: 1)
        XCTAssertFalse(resumed.blockedOnIndex)
        XCTAssertEqual(resumed.state.phase, .staged)
        XCTAssertEqual(resumed.objects.first?.descriptor, root.descriptor)
        XCTAssertEqual(resumed.objects.first?.nextOffset, root.bytes.count)
        XCTAssertEqual(resumed.objects.first?.source, .staged)
        XCTAssertNil(resumed.objects.first?.evaluation)
        try f.checkCapacity()
    }

    func testJournalPhaseAndRecoveryStatusRemainExplicitThroughApply() throws {
        let f = try Fixture(itemPayloads: [Data("phase object".utf8)])
        try f.begin()
        XCTAssertEqual(
            try f.journal.intakeState(context: f.context, packageID: f.manifest.packageID).phase, .staged)
        try f.appendWholeIndexes()
        let publication = PeerIntakeJournal.Publication(
            packageID: f.manifest.packageID,
            manifestDigest: AuthorityRecordCodec.sha256(f.manifestBytes), context: f.context,
            contextToken: f.context.configurationDigest, arrivalMinute: "2026/10/14/12/34")
        try f.journal.prepare(publication)
        let prepared = try f.journal.intakeState(context: f.context, packageID: f.manifest.packageID)
        XCTAssertEqual(prepared.phase, .prepared)
        XCTAssertFalse(prepared.recoveryRequired)

        try f.journal.seal(f.manifest.packageID)
        let sealed = try f.journal.intakeState(context: f.context, packageID: f.manifest.packageID)
        XCTAssertEqual(sealed.phase, .sealed)
        XCTAssertTrue(sealed.recoveryRequired)
        try f.journal.applied(f.manifest.packageID)
        let applied = try f.journal.intakeState(context: f.context, packageID: f.manifest.packageID)
        XCTAssertEqual(applied.phase, .applied)
        XCTAssertFalse(applied.recoveryRequired)
        try f.checkCapacity()
    }

    func testHierarchicalPagesResumeAfterReopenWithoutDuplicateItemRows() throws {
        let payloads = (0..<257).map { Data([UInt8($0 & 0xff)]) }
        let f = try Fixture(itemPayloads: payloads)
        try f.begin()
        try f.appendWholeIndexes()
        var cursor: PeerPackage.ResumeCursor?
        var seen: Set<String> = []
        var calls = 0
        var sawHeld = false
        let heldID = try XCTUnwrap(f.items.last?.descriptor.id)
        repeat {
            let page = try f.makeJournal().resumePage(
                context: f.context, packageID: f.manifest.packageID,
                cursor: cursor, limit: 37,
                evaluation: { object in
                    object.id == heldID
                        ? .init(disposition: .held, reason: "current authority requires review.") : nil
                })
            XCTAssertEqual(page.state.phase, .staged)
            XCTAssertFalse(page.blockedOnIndex)
            for object in page.objects where object.descriptor.kind == .item {
                XCTAssertEqual(object.source, .missing)
                XCTAssertEqual(object.nextOffset, 0)
                if object.descriptor.id == heldID {
                    XCTAssertEqual(object.evaluation?.disposition, .held)
                    sawHeld = true
                } else {
                    XCTAssertNil(object.evaluation)
                }
                XCTAssertTrue(seen.insert(object.descriptor.id).inserted)
            }
            cursor = page.nextCursor
            calls += 1
            XCTAssertLessThan(calls, 32)
        } while cursor != nil
        XCTAssertEqual(seen, Set(f.items.map { $0.descriptor.id }))
        XCTAssertGreaterThan(calls, 1)
        XCTAssertTrue(sawHeld)
        try f.checkCapacity()
    }

    func testVerifiedPrefixAndProofOnlyTailResumeAtPriorOffsetThenExactRetryCompletes() throws {
        let payload = Data(repeating: 0x5a, count: PeerPackage.maximumChunkBytes + 17)
        let f = try Fixture(itemPayloads: [payload])
        try f.begin()
        try f.appendWholeIndexes()
        let item = try XCTUnwrap(f.items.first)
        try f.append(item, offset: 0, bytes: Data(payload.prefix(PeerPackage.maximumChunkBytes)))
        let tail = Data(payload.suffix(17))
        let proof = PeerIntakeJournal.ChunkProof(
            object: item.descriptor, offset: PeerPackage.maximumChunkBytes, length: tail.count,
            sha256: AuthorityRecordCodec.sha256(tail))
        try f.write(
            try JSON.encode(proof),
            path: f.chunkPath(item, offset: PeerPackage.maximumChunkBytes, proof: true), maximum: 4096)

        let partial = try f.makeJournal().resumePage(context: f.context, packageID: f.manifest.packageID)
        let state = try XCTUnwrap(partial.objects.first { $0.descriptor.id == item.descriptor.id })
        XCTAssertEqual(state.source, .staged)
        XCTAssertEqual(state.nextOffset, PeerPackage.maximumChunkBytes)
        try f.append(item, offset: PeerPackage.maximumChunkBytes, bytes: tail, using: f.makeJournal())
        try f.append(item, offset: PeerPackage.maximumChunkBytes, bytes: tail, using: f.makeJournal())

        let complete = try f.makeJournal().resumePage(context: f.context, packageID: f.manifest.packageID)
        let resumed = try XCTUnwrap(complete.objects.first { $0.descriptor.id == item.descriptor.id })
        XCTAssertEqual(resumed.source, .staged)
        XCTAssertEqual(resumed.nextOffset, payload.count)
        XCTAssertEqual(try f.makeJournal().object(item.descriptor, packageID: f.manifest.packageID), payload)
        try f.checkCapacity()
    }

    func testUnprovedLegacyPrefixNeedsKnownOriginalAndCorruptChunkNeverClaimsOffset() throws {
        let payload = Data(repeating: 0x31, count: PeerPackage.maximumChunkBytes + 17)
        let f = try Fixture(itemPayloads: [payload])
        try f.begin()
        try f.appendWholeIndexes()
        let item = try XCTUnwrap(f.items.first)
        try f.append(item, offset: 0, bytes: Data(payload.prefix(PeerPackage.maximumChunkBytes)))
        try f.remove(f.chunkPath(item, offset: 0, proof: true))
        code("peerResumeProofMissing") {
            _ = try f.makeJournal().resumePage(context: f.context, packageID: f.manifest.packageID)
        }
        let verified = try f.makeJournal().resumePage(
            context: f.context, packageID: f.manifest.packageID,
            knownOriginal: { $0.id == item.descriptor.id ? payload : nil })
        let known = try XCTUnwrap(verified.objects.first { $0.descriptor.id == item.descriptor.id })
        XCTAssertEqual(known.source, .knownOriginal)
        XCTAssertEqual(known.nextOffset, payload.count)

        let chunkPath = f.root.appendingPathComponent(f.chunkPath(item, offset: 0).joined(separator: "/"))
        var changed = try Data(contentsOf: chunkPath)
        changed[0] ^= 1
        try changed.write(to: chunkPath, options: .atomic)
        code("peerObjectCollision") {
            _ = try f.makeJournal().resumePage(
                context: f.context, packageID: f.manifest.packageID,
                knownOriginal: { $0.id == item.descriptor.id ? payload : nil })
        }
        try f.checkCapacity()
    }

    func testManifestContextCursorLimitAndProgressCancellationAreBounded() throws {
        let f = try Fixture(itemPayloads: [Data("cursor item".utf8)])
        try f.begin()
        let first = try f.journal.resumePage(context: f.context, packageID: f.manifest.packageID)
        let cursor = try XCTUnwrap(first.nextCursor)
        let wrongContext = try PeerPackage.Context(
            peerID: f.context.peerID, storeID: f.context.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("changed configuration".utf8)),
            permittedOrigins: f.context.permittedOrigins)
        code("peerConfigurationChanged") {
            _ = try f.journal.intakeState(context: wrongContext, packageID: f.manifest.packageID)
        }
        code("resourceLimit") {
            _ = try f.journal.resumePage(context: f.context, packageID: f.manifest.packageID, limit: 129)
        }
        code("cancelled") {
            _ = try f.journal.resumePage(
                context: f.context, packageID: f.manifest.packageID, cursor: cursor,
                progress: { throw TractandaError("cancelled", "Test cancellation.") })
        }
        let other = try Fixture(itemPayloads: [Data("other package".utf8)])
        try other.begin()
        code("invalidPeerCursor") {
            _ = try other.journal.resumePage(
                context: other.context, packageID: other.manifest.packageID, cursor: cursor)
        }

        var readLimits = PeerPackage.Limits()
        readLimits.maximumReadBytes = 1
        let readLimited = try Fixture(itemPayloads: [Data("read budget".utf8)], limits: readLimits)
        try readLimited.begin()
        try readLimited.appendWholeIndexes()
        code("resourceLimit") {
            _ = try readLimited.journal.resumePage(
                context: readLimited.context, packageID: readLimited.manifest.packageID)
        }

        var workLimits = PeerPackage.Limits()
        workLimits.maximumWork = 1
        let workLimited = try Fixture(itemPayloads: [Data("work budget".utf8)], limits: workLimits)
        try workLimited.begin()
        try workLimited.appendWholeIndexes()
        code("resourceLimit") {
            _ = try workLimited.journal.resumePage(
                context: workLimited.context, packageID: workLimited.manifest.packageID)
        }
        try f.checkCapacity()
        try other.checkCapacity()
        try readLimited.checkCapacity()
        try workLimited.checkCapacity()
    }

    func testDurableIntentFaultReportsNoBytesAndExactRetryCompletesSameChunk() throws {
        let payload = Data(repeating: 0x6d, count: PeerPackage.maximumChunkBytes + 17)
        let f = try Fixture(itemPayloads: [payload])
        try f.begin()
        try f.appendWholeIndexes()
        let item = try XCTUnwrap(f.items.first)
        let first = Data(payload.prefix(PeerPackage.maximumChunkBytes))
        f.journal.afterChunkIntentForTesting = { throw TractandaError("interrupted", "After intent.") }
        XCTAssertThrowsError(try f.append(item, offset: 0, bytes: first))
        f.journal.afterChunkIntentForTesting = nil
        XCTAssertNotNil(
            try f.journal.files.readIfPresent(
                path: f.chunkPath(item, offset: 0, proof: true), maximumBytes: 4096))
        XCTAssertNil(
            try f.journal.files.readIfPresent(
                path: f.chunkPath(item, offset: 0), maximumBytes: PeerPackage.maximumChunkBytes))

        let reopened = f.makeJournal()
        let interrupted = try reopened.resumePage(context: f.context, packageID: f.manifest.packageID)
        let missing = try XCTUnwrap(interrupted.objects.first { $0.descriptor.id == item.descriptor.id })
        XCTAssertEqual(missing.source, .missing)
        XCTAssertEqual(missing.nextOffset, 0)

        var different = first
        different[0] ^= 1
        code("peerObjectCollision") { try f.append(item, offset: 0, bytes: different, using: reopened) }
        try f.append(item, offset: 0, bytes: first, using: reopened)
        let verifiedPrefix = try reopened.resumePage(context: f.context, packageID: f.manifest.packageID)
        XCTAssertEqual(
            try XCTUnwrap(verifiedPrefix.objects.first { $0.descriptor.id == item.descriptor.id }).nextOffset,
            PeerPackage.maximumChunkBytes)
        try f.append(
            item, offset: PeerPackage.maximumChunkBytes, bytes: Data(payload.suffix(17)), using: reopened)
        XCTAssertEqual(try reopened.object(item.descriptor, packageID: f.manifest.packageID), payload)
        try f.checkCapacity()
    }

    func testTruncatedIntentCorruptChunkTinyQuotaAndInvalidFramingFailClosed() throws {
        let proofFixture = try Fixture(itemPayloads: [Data("truncated intent".utf8)])
        try proofFixture.begin()
        try proofFixture.appendWholeIndexes()
        let proofItem = try XCTUnwrap(proofFixture.items.first)
        proofFixture.journal.afterChunkIntentForTesting = {
            throw TractandaError("interrupted", "After intent.")
        }
        XCTAssertThrowsError(try proofFixture.append(proofItem))
        proofFixture.journal.afterChunkIntentForTesting = nil
        try proofFixture.remove(proofFixture.chunkPath(proofItem, offset: 0, proof: true))
        try proofFixture.write(
            Data("{".utf8), path: proofFixture.chunkPath(proofItem, offset: 0, proof: true), maximum: 4096)
        XCTAssertThrowsError(
            try proofFixture.makeJournal().resumePage(
                context: proofFixture.context, packageID: proofFixture.manifest.packageID))
        try proofFixture.checkCapacity()

        let corruptPayload = Data(repeating: 0x44, count: 128)
        let corruptFixture = try Fixture(itemPayloads: [corruptPayload])
        try corruptFixture.begin()
        try corruptFixture.appendWholeIndexes()
        let corruptItem = try XCTUnwrap(corruptFixture.items.first)
        try corruptFixture.append(corruptItem)
        let chunk = corruptFixture.root.appendingPathComponent(
            corruptFixture.chunkPath(corruptItem, offset: 0).joined(separator: "/"))
        var changed = try Data(contentsOf: chunk)
        changed[0] ^= 1
        try changed.write(to: chunk, options: .atomic)
        code("peerObjectCollision") {
            _ = try corruptFixture.makeJournal().resumePage(
                context: corruptFixture.context, packageID: corruptFixture.manifest.packageID)
        }
        try changed.dropLast().write(to: chunk, options: .atomic)
        code("invalidPeerPackage") {
            _ = try corruptFixture.makeJournal().resumePage(
                context: corruptFixture.context, packageID: corruptFixture.manifest.packageID)
        }
        try corruptFixture.checkCapacity()

        let quotaFixture = try Fixture(itemPayloads: [Data(repeating: 0x72, count: 900)])
        let quotaItem = try XCTUnwrap(quotaFixture.items.first)
        var tinyLimits = PeerPackage.Limits()
        // Without the intent charge this exact begin + descriptor + body would fit. The
        // write-ahead checksum metadata must make append fail before any object file exists.
        tinyLimits.maximumStagedBytes = UInt64(
            try JSON.encode(
                PeerIntakeJournal.Begin(
                    manifest: quotaFixture.manifest, context: quotaFixture.context)
            ).count
                + JSON.encode(quotaItem.descriptor).count + quotaItem.bytes.count)
        let limitedJournal = PeerIntakeJournal(
            root: quotaFixture.root, ownerUID: quotaFixture.ownerUID, limits: tinyLimits)
        _ = try limitedJournal.begin(context: quotaFixture.context, manifestBytes: quotaFixture.manifestBytes)
        code("resourceLimit") { try quotaFixture.append(quotaItem, using: limitedJournal) }
        XCTAssertNil(
            try quotaFixture.journal.files.readIfPresent(
                path: [
                    "authority", "intake", quotaFixture.manifest.packageID, "objects",
                    quotaItem.descriptor.id, "descriptor.json",
                ], maximumBytes: PeerPackage.maximumPageBytes))
        XCTAssertNil(
            try quotaFixture.journal.files.readIfPresent(
                path: quotaFixture.chunkPath(quotaItem, offset: 0, proof: true), maximumBytes: 4096))
        XCTAssertNil(
            try quotaFixture.journal.files.readIfPresent(
                path: quotaFixture.chunkPath(quotaItem, offset: 0),
                maximumBytes: PeerPackage.maximumChunkBytes))
        try quotaFixture.checkCapacity()

        let framedPayload = Data(repeating: 0x3a, count: PeerPackage.maximumChunkBytes + 17)
        let framingFixture = try Fixture(itemPayloads: [framedPayload])
        try framingFixture.begin()
        let framedItem = try XCTUnwrap(framingFixture.items.first)
        code("invalidPeerOffset") {
            try framingFixture.append(
                framedItem, offset: 0, bytes: Data(repeating: 0x3a, count: 17))
        }
        XCTAssertNil(
            try framingFixture.journal.files.readIfPresent(
                path: [
                    "authority", "intake", framingFixture.manifest.packageID, "objects",
                    framedItem.descriptor.id, "descriptor.json",
                ], maximumBytes: PeerPackage.maximumPageBytes))
        XCTAssertNil(
            try framingFixture.journal.files.readIfPresent(
                path: framingFixture.chunkPath(framedItem, offset: 0, proof: true), maximumBytes: 4096))
        try framingFixture.checkCapacity()
    }
}
