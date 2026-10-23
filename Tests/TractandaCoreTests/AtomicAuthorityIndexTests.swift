import CSQLite
import CTractandaPlatform
import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class AtomicAuthorityIndexTests: XCTestCase {
    private typealias Archive = AtomicAuthorityArchive
    private func id(_ n: Int) -> String { String(format: "%08x-0000-1000-8000-000000000001", n) }
    private func binding(_ n: Int) -> AuthorityBinding {
        try! .init(recordID: id(n), sha256: String(repeating: "a", count: 64))
    }
    private func fact(_ n: Int, evidence: Int = 99) -> ItemValue {
        AuthorityStore.DispositionDelta(
            target: try! .init(
                itemID: id(10 + n), revisionID: id(100 + n), sha256: String(repeating: "f", count: 64)),
            eligible: false, actor: "user:rcfa", policyIDs: [id(80)], causes: [binding(90)],
            evidence: binding(evidence)
        ).itemValue
    }
    private func ordered(_ facts: [ItemValue]) throws -> [ItemValue] {
        try facts.map {
            (
                try AuthorityStore.DispositionDelta(value: $0).target.revisionID + ":"
                    + AuthorityRecordCodec.sha256(JSON.encode($0)), $0
            )
        }.sorted { $0.0 < $1.0 }.map(\.1)
    }
    private final class Fixture {
        let root: URL
        let index: ItemIndex
        let archive: Archive
        init(chunkBytes: Int = 257) throws {
            try AttachmentFixtureCapacity.requireFree()
            root = try GuardedFixtureDirectory.create(
                prefix: "atomic-index-", source: #filePath, test: #function)
            let path = root.appendingPathComponent("archive")
            try FileManager.default.createDirectory(
                at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            archive = try .init(
                root: path, limits: .init(maximumStoredBytes: 8 * 1024 * 1024, maximumParts: 4096),
                chunkBytes: chunkBytes)
            index = try ItemIndex(path: root.appendingPathComponent("index.sqlite").path, create: true)
            index.graphReserveBytes = UInt64(AttachmentFixtureCapacity.reserveBytes)
            try index.validateRecoveryGraph(requireLinearProjection: false)
            try index.initializeAuthoritySchema()
            try index.initializeAuthorityControlSchema()
            try index.initializeAtomicAuthoritySchema()
        }
        func remove(file: StaticString = #filePath, line: UInt = #line) {
            index.close()
            if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
                for case let url as URL in e {
                    var s = stat()
                    if lstat(url.path, &s) == 0, s.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) {
                        _ = chmod(url.path, 0o600)
                    }
                }
            }
            XCTAssertNoThrow(try FileManager.default.removeItem(at: root), file: file, line: line)
        }
    }
    private func build(_ f: Fixture, facts: [ItemValue], parents: [AuthorityBinding] = []) throws
        -> Archive.Handle
    {
        var p = parents.map(\.itemValue).makeIterator()
        var d = try ordered(facts).makeIterator()
        return try f.archive.build(
            context: .init(
                rootID: id(1), storeID: id(2), origin: id(3), actor: "user:rcfa",
                createdAt: "2026-10-23T10:00:00.000Z", inputIdentity: String(repeating: "b", count: 64),
                previous: parents.first),
            parents: { p.next() }, effects: { d.next() })
    }

    func testCompleteStructuralStagePreservesDuplicateTargetSupportContextsWithoutAuthority() throws {
        let f = try Fixture()
        defer { f.remove() }
        let facts = try ordered([fact(0), fact(0, evidence: 98), fact(1)])
        let parents = [binding(40), binding(41)]
        let handle = try build(f, facts: facts, parents: parents)
        let stage = try f.index.stageAtomicControl(archive: f.archive, handle: handle)
        let source = LogicalControlSource.atomic(stage)
        XCTAssertEqual(try source.header().binding, handle.binding)
        XCTAssertEqual(try source.header().createdAt, "2026-10-23T10:00:00.000Z")
        XCTAssertEqual(stage.effects.entryCount, 3)
        XCTAssertEqual(stage.effects.targetCount, 2)
        var actual: [ItemValue] = []
        var cursor: Int64 = -1
        while let next = try source.supports(index: f.index, afterOrdinal: cursor, limit: 1).first {
            actual.append(next.delta.itemValue)
            cursor = next.ordinal
        }
        XCTAssertEqual(actual, facts)
        XCTAssertEqual(try source.parents(index: f.index, limit: 1).map(\.binding), [parents[0]])
        XCTAssertEqual(
            try source.parents(index: f.index, afterOrdinal: 0, limit: 1).map(\.binding), [parents[1]])
        XCTAssertFalse(try f.index.hasValidatedAuthorityControl(handle.binding))
        XCTAssertNil(try f.index.authorityControlHead(originID: id(3)))
        XCTAssertEqual(
            try f.index.eligibilityAtCut(
                revisionID: id(100), cut: handle.binding), .unknown)
        XCTAssertEqual(try f.index.stageAtomicControl(archive: f.archive, handle: handle), stage)
        XCTAssertEqual(try source.supports(index: f.index).count, 3, "Exact retry cannot duplicate facts")
    }

    func testInterruptedPrivateStageIsInvisibleAndExactRetryCompletes() throws {
        let f = try Fixture()
        defer { f.remove() }
        let facts = try ordered([fact(0), fact(1)])
        let handle = try build(f, facts: facts)
        let stage = try AtomicControlStage(rootBytes: f.archive.rootBytes(handle))
        try f.index.beginAtomicControlStage(stage)
        try f.index.appendAtomicControlEntry(stage, section: .effects, ordinal: 0, value: facts[0])
        XCTAssertThrowsError(try f.index.finishAtomicControlStage(stage))
        XCTAssertThrowsError(try LogicalControlSource.atomic(stage).supports(index: f.index))
        XCTAssertFalse(try f.index.hasValidatedAuthorityControl(handle.binding))
        XCTAssertEqual(try f.index.stageAtomicControl(archive: f.archive, handle: handle), stage)
        XCTAssertEqual(
            try LogicalControlSource.atomic(stage).supports(index: f.index).map(\.delta.itemValue), facts)
    }

    func testChangedRetryGapAndOutOfOrderFactsCannotChangeStage() throws {
        let f = try Fixture()
        defer { f.remove() }
        let facts = try ordered([fact(0), fact(1)])
        let handle = try build(f, facts: facts)
        let stage = try AtomicControlStage(rootBytes: f.archive.rootBytes(handle))
        try f.index.beginAtomicControlStage(stage)
        XCTAssertThrowsError(
            try f.index.appendAtomicControlEntry(stage, section: .effects, ordinal: 1, value: facts[1]))
        try f.index.appendAtomicControlEntry(stage, section: .effects, ordinal: 0, value: facts[0])
        XCTAssertThrowsError(
            try f.index.appendAtomicControlEntry(stage, section: .effects, ordinal: 0, value: fact(2)))
        XCTAssertThrowsError(
            try f.index.appendAtomicControlEntry(stage, section: .effects, ordinal: 1, value: facts[0]))
        XCTAssertNoThrow(try f.index.stageAtomicControl(archive: f.archive, handle: handle))
        XCTAssertEqual(
            try LogicalControlSource.atomic(stage).supports(index: f.index).map(\.delta.itemValue), facts)
    }

    func testStageCannotRebindRootOrExposeTamperedSupport() throws {
        let f = try Fixture()
        defer { f.remove() }
        let handle = try build(f, facts: [fact(0)])
        let stage = try f.index.stageAtomicControl(archive: f.archive, handle: handle)
        var value = try AtomicAuthorityFormat.Codec.decode(stage.rootBytes).itemValue.map!
        value["actorPrincipal"] = .text("user:other")
        let changed = try AtomicControlStage(
            rootBytes: AtomicAuthorityFormat.Codec.encode(.init(value: .object(value))))
        XCTAssertThrowsError(try f.index.beginAtomicControlStage(changed))
        try f.index.execute(
            "UPDATE authority_atomic_support_stage SET payload=? WHERE root=?",
            [String(decoding: try JSON.encode(fact(1)), as: UTF8.self), id(1)])
        XCTAssertThrowsError(try LogicalControlSource.atomic(stage).supports(index: f.index))
        XCTAssertFalse(try f.index.hasValidatedAuthorityControl(handle.binding))
        XCTAssertNil(try f.index.authorityControlHead(originID: id(3)))
    }

    func testStagingSurvivesReopenButNeverBecomesAcceptedControl() throws {
        let f = try Fixture()
        defer { f.remove() }
        let handle = try build(f, facts: [fact(0)])
        let stage = try f.index.stageAtomicControl(archive: f.archive, handle: handle)
        f.index.close()
        let reopened = try ItemIndex(path: f.root.appendingPathComponent("index.sqlite").path, create: false)
        defer { reopened.close() }
        XCTAssertEqual(
            try LogicalControlSource.atomic(stage).supports(index: reopened).map(\.delta.itemValue), [fact(0)]
        )
        XCTAssertFalse(try reopened.hasValidatedAuthorityControl(handle.binding))
        XCTAssertNil(try reopened.authorityControlHead(originID: id(3)))
    }

    func testCursorBoundsAndCancellationPreserveNoAuthority() throws {
        let f = try Fixture()
        defer { f.remove() }
        let handle = try build(f, facts: [fact(0)])
        let stage = try f.index.stageAtomicControl(archive: f.archive, handle: handle)
        let source = LogicalControlSource.atomic(stage)
        XCTAssertThrowsError(try source.supports(index: f.index, limit: 0))
        XCTAssertThrowsError(try source.parents(index: f.index, afterOrdinal: -2))
        XCTAssertThrowsError(
            try f.index.withCatalogueScanBudget(progress: { throw CancellationError() }) {
                try source.supports(index: f.index)
            })
        XCTAssertNoThrow(try source.supports(index: f.index))
        XCTAssertFalse(try f.index.hasValidatedAuthorityControl(handle.binding))
    }

    func testFinalCanonicalComparisonRejectsChangedFactEvenWithRecomputedFingerprint() throws {
        let f = try Fixture()
        defer { f.remove() }
        let handle = try build(f, facts: [fact(0)])
        let stage = try f.index.stageAtomicControl(archive: f.archive, handle: handle)
        var entered = false
        try f.index.withCanonicalAtomicStage(stage, archive: f.archive, handle: handle) { _ in entered = true
        }
        XCTAssertTrue(entered)
        let changed = try JSON.encode(fact(0, evidence: 98))
        try f.index.execute(
            "UPDATE authority_atomic_support_stage SET payload=?,fingerprint=? WHERE root=?",
            [String(decoding: changed, as: UTF8.self), AuthorityRecordCodec.sha256(changed), id(1)])
        entered = false
        XCTAssertThrowsError(
            try f.index.withCanonicalAtomicStage(stage, archive: f.archive, handle: handle) { _ in
                entered = true
            })
        XCTAssertFalse(entered, "A self-consistent SQLite hash is not canonical proof")
        XCTAssertFalse(try f.index.hasValidatedAuthorityControl(handle.binding))
    }

    func testFinalCanonicalComparisonRejectsChangedParentAndExtraFact() throws {
        let f = try Fixture()
        defer { f.remove() }
        let parents = [binding(40), binding(41)]
        let handle = try build(f, facts: [fact(0)], parents: parents)
        let stage = try f.index.stageAtomicControl(archive: f.archive, handle: handle)
        try f.index.execute(
            "UPDATE authority_atomic_parent_stage SET sha256=? WHERE root=? AND ordinal=1",
            [String(repeating: "b", count: 64), id(1)])
        var entered = false
        XCTAssertThrowsError(
            try f.index.withCanonicalAtomicStage(stage, archive: f.archive, handle: handle) { _ in
                entered = true
            })
        XCTAssertFalse(entered)
        try f.index.execute(
            "UPDATE authority_atomic_parent_stage SET sha256=? WHERE root=? AND ordinal=1",
            [parents[1].sha256, id(1)])
        let extra = try JSON.encode(fact(1))
        try f.index.execute(
            "INSERT INTO authority_atomic_support_stage VALUES(?,?,?,?,?)",
            [id(1), "1", id(101), AuthorityRecordCodec.sha256(extra), String(decoding: extra, as: UTF8.self)])
        XCTAssertThrowsError(
            try f.index.withCanonicalAtomicStage(stage, archive: f.archive, handle: handle) { _ in
                entered = true
            })
        XCTAssertFalse(entered)
    }

    func testFinalCanonicalComparisonRejectsNegativeOrdinalInEitherStagedSection() throws {
        let f = try Fixture()
        defer { f.remove() }
        let handle = try build(f, facts: [fact(0)], parents: [binding(40)])
        let stage = try f.index.stageAtomicControl(archive: f.archive, handle: handle)
        try f.index.execute(
            "INSERT INTO authority_atomic_parent_stage VALUES(?,?,?,?)",
            [id(1), "-1", binding(41).recordID, binding(41).sha256])
        var entered = false
        XCTAssertThrowsError(
            try f.index.withCanonicalAtomicStage(stage, archive: f.archive, handle: handle) { _ in
                entered = true
            })
        XCTAssertFalse(entered)
        try f.index.execute("DELETE FROM authority_atomic_parent_stage WHERE root=? AND ordinal<0", [id(1)])
        let bytes = try JSON.encode(fact(1))
        try f.index.execute(
            "INSERT INTO authority_atomic_support_stage VALUES(?,?,?,?,?)",
            [
                id(1), "-1", id(101), AuthorityRecordCodec.sha256(bytes),
                String(decoding: bytes, as: UTF8.self),
            ])
        XCTAssertThrowsError(
            try f.index.withCanonicalAtomicStage(stage, archive: f.archive, handle: handle) { _ in
                entered = true
            })
        XCTAssertFalse(entered)
        XCTAssertFalse(try f.index.hasValidatedAuthorityControl(handle.binding))
    }

    func testFinalCanonicalComparisonRejectsFractionalAndTextOrdinalsDespiteMatchingCounters() throws {
        let f = try Fixture()
        defer { f.remove() }
        let handle = try build(f, facts: [fact(0)], parents: [binding(40)])
        let stage = try f.index.stageAtomicControl(archive: f.archive, handle: handle)
        for ordinal in ["0.5", "not-an-ordinal"] {
            var entered = false
            try f.index.execute(
                "INSERT INTO authority_atomic_parent_stage VALUES(?,?,?,?)",
                [id(1), ordinal, binding(41).recordID, binding(41).sha256])
            XCTAssertThrowsError(
                try f.index.withCanonicalAtomicStage(stage, archive: f.archive, handle: handle) { _ in
                    entered = true
                })
            XCTAssertFalse(entered)
            try f.index.execute(
                "DELETE FROM authority_atomic_parent_stage WHERE root=? AND id=?",
                [id(1), binding(41).recordID])
            let bytes = try JSON.encode(fact(1))
            try f.index.execute(
                "INSERT INTO authority_atomic_support_stage VALUES(?,?,?,?,?)",
                [
                    id(1), ordinal, id(101), AuthorityRecordCodec.sha256(bytes),
                    String(decoding: bytes, as: UTF8.self),
                ])
            XCTAssertThrowsError(
                try f.index.withCanonicalAtomicStage(stage, archive: f.archive, handle: handle) { _ in
                    entered = true
                })
            XCTAssertFalse(entered)
            try f.index.execute(
                "DELETE FROM authority_atomic_support_stage WHERE root=? AND target=?", [id(1), id(101)])
        }
        XCTAssertFalse(try f.index.hasValidatedAuthorityControl(handle.binding))
    }

    func testRetainedOriginalLoaderReusesWalkerWithoutCopyingPartsAndRechecksEachRead() throws {
        let f = try Fixture()
        defer { f.remove() }
        let handle = try build(f, facts: [fact(0), fact(1)], parents: [binding(40)])
        let privateWork = f.root.appendingPathComponent("reader")
        try FileManager.default.createDirectory(
            at: privateWork, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var tamper = false
        var reads = 0
        let reader = try Archive(
            root: privateWork, limits: .init(maximumStoredBytes: 8 * 1024 * 1024, maximumParts: 4096),
            canonicalPartLoader: { binding, length in
                reads += 1
                // The actual Store loader uses coordinator.bytes (descriptor-relative nofollow,
                // custody/full stamp, operation read budget and immutable-byte memo). This private
                // loader tests the common walker's independent ID/hash/length/context checks.
                let bytes = try Data(
                    contentsOf: f.root.appendingPathComponent("archive/parts/" + binding.recordID))
                XCTAssertEqual(bytes.count, Int(length))
                return tamper ? Data("changed".utf8) : bytes
            }, canonicalRootLoader: { try f.archive.rootBytes(handle) })
        let bound = try reader.bindCanonicalRoot(f.archive.rootBytes(handle))
        XCTAssertEqual(bound, handle)
        let stage = try f.index.stageAtomicControl(archive: reader, handle: bound)
        let canonical = try CanonicalAuthorityOriginal(stage.rootBytes)
        XCTAssertEqual(canonical.recordID, handle.binding.recordID)
        XCTAssertEqual(canonical.kind, "atomicControl")
        XCTAssertNil(canonical.legacy)
        XCTAssertFalse(try canonical.physicalChildren().isEmpty)
        let partCount = try AtomicAuthorityFormat.Codec.decode(stage.rootBytes).payload["partCount"]!
            .integerValue!
        XCTAssertEqual(
            Int64(reads), partCount, "One structural staging pass, no full-tree reread per SQL row")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: privateWork.appendingPathComponent("parts").path))
        var finalized = false
        reads = 0
        try f.index.withCanonicalAtomicStage(stage, archive: reader, handle: bound) { _ in finalized = true }
        XCTAssertTrue(finalized)
        XCTAssertEqual(Int64(reads), partCount, "One canonical-to-stage comparison walk")
        tamper = true
        finalized = false
        XCTAssertThrowsError(
            try f.index.withCanonicalAtomicStage(stage, archive: reader, handle: bound) { _ in
                finalized = true
            })
        XCTAssertFalse(finalized)
        XCTAssertFalse(try f.index.hasValidatedAuthorityControl(handle.binding))
        tamper = false
        let sourceRoot = f.root.appendingPathComponent("archive/root")
        XCTAssertEqual(chmod(sourceRoot.path, 0o600), 0)
        try Data("changed canonical root".utf8).write(to: sourceRoot)
        XCTAssertEqual(chmod(sourceRoot.path, 0o400), 0)
        XCTAssertThrowsError(
            try f.index.withCanonicalAtomicStage(stage, archive: reader, handle: bound) { _ in
                finalized = true
            })
        XCTAssertFalse(finalized, "A copied root cannot hide changed canonical root custody/bytes")
    }

    func testPrivateStageWritesPreserveExistingGraphAdmissionProof() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.index.validateRecoveryGraph(requireLinearProjection: false)
        let before = f.index.captureAuthorityPeerGraphState()
        let handle = try build(f, facts: [fact(0)])
        _ = try f.index.stageAtomicControl(archive: f.archive, handle: handle)
        let after = f.index.captureAuthorityPeerGraphState()
        XCTAssertEqual(after.watermark, before.watermark)
        XCTAssertEqual(after.linear, before.linear)
        XCTAssertNotNil(after.watermark)
        XCTAssertFalse(try f.index.hasValidatedAuthorityControl(handle.binding))
    }

    func testFixedSchemaCreationPreservesGraphProofButAcceptedDataMutationInvalidatesIt() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.index.validateRecoveryGraph(requireLinearProjection: false)
        let before = f.index.captureAuthorityPeerGraphState()
        try f.index.initializeAtomicAuthorityAcceptedSchema()
        XCTAssertEqual(f.index.captureAuthorityPeerGraphState().watermark, before.watermark)
        XCTAssertNotNil(before.watermark)
        // Direct private-fixture corruption, not an acceptance API: the normal data-write path
        // must invalidate proof, while exact accepted-root joins prevent this row granting rights.
        try f.index.execute(
            "INSERT INTO authority_atomic_outcome VALUES(?,?,?,?,?,?)",
            [
                id(1), String(repeating: "a", count: 64), id(100), id(10), String(repeating: "f", count: 64),
                "1",
            ])
        XCTAssertNil(f.index.captureAuthorityPeerGraphState().watermark)
        let s = try f.index.corpusPrepare("SELECT COUNT(*) FROM authority_control_outcomes")
        defer { sqlite3_finalize(s) }
        XCTAssertEqual(f.index.catalogueStep(s), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int64(s, 0), 0)
    }

    func testInvalidFinalPartLeavesOnlyUntrustedPrefixAndExactRetryCompletes() throws {
        let f = try Fixture()
        defer { f.remove() }
        let handle = try build(f, facts: [fact(0), fact(1), fact(2)])
        let directory = f.root.appendingPathComponent("archive/parts")
        let leaves = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).compactMap {
            url -> (URL, AtomicAuthorityFormat.Record)? in
            let record = try AtomicAuthorityFormat.Codec.decode(Data(contentsOf: url))
            return record.kind == .atomicControlPart && record.section == .effects ? (url, record) : nil
        }.sorted { $0.1.payload["ordinal"]!.integerValue! < $1.1.payload["ordinal"]!.integerValue! }
        let last = try XCTUnwrap(leaves.last?.0)
        let original = try Data(contentsOf: last)
        XCTAssertEqual(chmod(last.path, 0o600), 0)
        try Data("bad final part".utf8).write(to: last)
        XCTAssertEqual(chmod(last.path, 0o400), 0)
        XCTAssertThrowsError(try f.index.stageAtomicControl(archive: f.archive, handle: handle))
        let stage = try AtomicControlStage(rootBytes: f.archive.rootBytes(handle))
        XCTAssertThrowsError(try LogicalControlSource.atomic(stage).supports(index: f.index))
        XCTAssertFalse(try f.index.hasValidatedAuthorityControl(handle.binding))
        XCTAssertEqual(chmod(last.path, 0o600), 0)
        try original.write(to: last)
        XCTAssertEqual(chmod(last.path, 0o400), 0)
        XCTAssertNoThrow(try f.index.stageAtomicControl(archive: f.archive, handle: handle))
        XCTAssertEqual(try LogicalControlSource.atomic(stage).supports(index: f.index).count, 3)
    }

    func testCancelledUntrustedWindowCannotCompleteAndPrefixRetryIsExact() throws {
        let f = try Fixture()
        defer { f.remove() }
        let handle = try build(f, facts: [fact(0), fact(1)])
        let stage = try AtomicControlStage(rootBytes: f.archive.rootBytes(handle))
        try f.index.beginAtomicControlStage(stage)
        let reader = try f.archive.beginValidation(handle)
        var emitted = 0
        XCTAssertThrowsError(
            try {
                while try reader.stageWindow(
                    window: .init(maximumParts: 1, maximumBytes: AtomicAuthorityFormat.maximumEnvelopeBytes),
                    onUntrustedFact: { fact in
                        try f.index.appendAtomicControlEntry(
                            stage, section: fact.section, ordinal: 0, value: fact.value)
                        emitted += 1
                        throw CancellationError()
                    }) == nil
                {}
            }())
        XCTAssertEqual(emitted, 1)
        try reader.close()
        XCTAssertThrowsError(try f.index.finishAtomicControlStage(stage))
        XCTAssertThrowsError(try LogicalControlSource.atomic(stage).supports(index: f.index))
        XCTAssertFalse(try f.index.hasValidatedAuthorityControl(handle.binding))
        XCTAssertNoThrow(try f.index.stageAtomicControl(archive: f.archive, handle: handle))
        XCTAssertEqual(try LogicalControlSource.atomic(stage).supports(index: f.index).count, 2)
    }

    func testCanonicalRootAndPartsRetainAsBytesWithoutAcceptedFactsOrHeads() throws {
        let f = try Fixture()
        defer { f.remove() }
        let handle = try build(f, facts: [fact(0), fact(0, evidence: 98)])
        let stage = try f.index.stageAtomicControl(archive: f.archive, handle: handle)
        try f.index.initializeAtomicAuthorityAcceptedSchema()
        let authority = f.root.appendingPathComponent("authority")
        try FileManager.default.createDirectory(
            at: authority, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        func retain(_ bytes: Data) throws -> CanonicalAuthorityOriginal {
            let original = try CanonicalAuthorityOriginal(bytes)
            let path = "authority/" + original.recordID + ".tractanda"
            let url = f.root.appendingPathComponent(path)
            try bytes.write(to: url)
            XCTAssertEqual(chmod(url.path, 0o400), 0)
            try f.index.retainAuthorityObject(
                .init(
                    descriptor: .init(
                        kind: .authority, id: original.recordID, length: bytes.count, sha256: original.sha256),
                    path: path, packageID: id(900), peerID: "fixture",
                    configurationDigest: String(repeating: "c", count: 64), permittedOrigin: true),
                revision: nil, authority: nil, atomic: original)
            return original
        }
        let root = try retain(stage.rootBytes)
        let parts = try FileManager.default.contentsOfDirectory(
            at: f.root.appendingPathComponent("archive/parts"), includingPropertiesForKeys: nil)
        for part in parts {
            let original = try retain(Data(contentsOf: part))
            XCTAssertFalse(
                try f.index.hasValidatedAuthorityControl(
                    .init(recordID: original.recordID, sha256: original.sha256)))
        }
        XCTAssertFalse(try f.index.hasValidatedAuthorityControl(handle.binding))
        XCTAssertNil(try f.index.authorityControlHead(originID: root.origin))
        for view in ["authority_control_facts", "authority_control_outcomes"] {
            let s = try f.index.corpusPrepare("SELECT COUNT(*) FROM \(view)")
            defer { sqlite3_finalize(s) }
            XCTAssertEqual(f.index.catalogueStep(s), SQLITE_ROW)
            XCTAssertEqual(sqlite3_column_int64(s, 0), 0)
        }
        let plan = try AuthorityStore.VerifiedAtomicControlPlan(
            stage: stage, contextDigest: String(repeating: "d", count: 64))
        XCTAssertThrowsError(
            try f.index.retainValidatedAtomicControl(plan),
            "No Store canonical finalization or semantic acceptance is active")
        XCTAssertFalse(try f.index.hasValidatedAuthorityControl(handle.binding))
    }
    func testResumableCanonicalComparisonReadsEachPartOnceAcrossSmallWindows() throws {
        let f = try Fixture(chunkBytes: 4096)
        defer { f.remove() }
        let handle = try build(f, facts: (0..<192).map { fact($0) }, parents: [binding(40)])
        let privateWork = f.root.appendingPathComponent("window-reader")
        try FileManager.default.createDirectory(
            at: privateWork, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        var reads: Int64 = 0
        let archive = try Archive(
            root: privateWork,
            limits: .init(maximumStoredBytes: 8 * 1024 * 1024, maximumParts: 4096),
            canonicalPartLoader: { binding, _ in
                reads += 1
                return try Data(
                    contentsOf: f.root.appendingPathComponent("archive/parts/" + binding.recordID))
            }, canonicalRootLoader: { try f.archive.rootBytes(handle) })
        _ = try archive.bindCanonicalRoot(f.archive.rootBytes(handle))
        let stage = try f.index.stageAtomicControl(archive: archive, handle: handle)
        reads = 0
        var contextValid = true
        let work = try AtomicAuthorityStageValidation(
            index: f.index, stage: stage,
            archive: archive, handle: handle,
            contextCheck: {
                if !contextValid { throw TractandaError("testContextChanged", "Changed current context.") }
            })
        defer { try? work.close() }
        // One outer window is genuinely too small: it yields without resetting the budget or
        // throwing through the parser. The next ordinary request owns its own bounded allowance.
        f.index.graphMaximumVMInstructions = 512
        XCTAssertFalse(try f.index.withCatalogueScanBudget { try work.step(maximumFacts: 1) })
        XCTAssertEqual(reads, 0)
        XCTAssertLessThan(f.index.lastCatalogueScanWorkForTesting, 512)
        f.index.graphMaximumVMInstructions = 6_000
        var windows = 0
        var charged: Int64 = 0
        while !work.complete {
            _ = try f.index.withCatalogueScanBudget { try work.step(maximumFacts: 1) }
            charged += f.index.lastCatalogueScanWorkForTesting
            windows += 1
            XCTAssertLessThan(windows, 2_000)
        }
        XCTAssertGreaterThan(charged, f.index.graphMaximumVMInstructions)
        XCTAssertEqual(work.comparedFacts, 193)
        XCTAssertEqual(
            reads, try AtomicAuthorityFormat.Codec.decode(stage.rootBytes).payload["partCount"]?.integerValue)
        var entered = false
        try work.withFinalWriter { _ in entered = true }
        XCTAssertTrue(entered)
        XCTAssertFalse(
            try f.index.hasValidatedAuthorityControl(handle.binding), "Comparison is not semantic acceptance")
        contextValid = false
    }

    func testResumableComparisonRejectsPreparedPrefixMutationWithForgedFingerprint() throws {
        let f = try Fixture()
        defer { f.remove() }
        let handle = try build(f, facts: [fact(0), fact(1)])
        let stage = try f.index.stageAtomicControl(archive: f.archive, handle: handle)
        let changed = try JSON.encode(fact(0, evidence: 98))
        // Prepared before freeze, so only the executed-write epoch (not prepare's SQL guard)
        // can detect a rewrite of an already-compared prefix, even with a matching fake hash.
        let mutation = try f.index.corpusPrepare(
            "UPDATE authority_atomic_support_stage SET payload=?,fingerprint=? WHERE root=? AND ordinal=0",
            [String(decoding: changed, as: UTF8.self), AuthorityRecordCodec.sha256(changed), id(1)])
        defer { sqlite3_finalize(mutation) }
        let work = try AtomicAuthorityStageValidation(
            index: f.index, stage: stage,
            archive: f.archive, handle: handle, contextCheck: {})
        defer { try? work.close() }
        while work.comparedFacts == 0 { _ = try work.step(maximumFacts: 1) }
        XCTAssertThrowsError(
            try f.index.execute(
                "UPDATE authority_atomic_support_stage SET payload=payload WHERE root=?", [id(1)]))
        XCTAssertEqual(sqlite3_step(mutation), SQLITE_DONE)
        XCTAssertThrowsError(try work.step(maximumFacts: 1))
        XCTAssertThrowsError(try work.withFinalWriter { _ in XCTFail("Stale prefix accepted") })
        XCTAssertFalse(try f.index.hasValidatedAuthorityControl(handle.binding))
        // Failure releases only its owned freeze; the private stage remains untrusted/retriable.
        XCTAssertNoThrow(
            try f.index.execute(
                "UPDATE authority_atomic_support_stage SET payload=payload WHERE root=?", [id(1)]))
    }

    func testResumableComparisonRejectsForeignStageWriteAndFreshContextChange() throws {
        let f = try Fixture()
        defer { f.remove() }
        let handle = try build(f, facts: [fact(0), fact(1)])
        let stage = try f.index.stageAtomicControl(archive: f.archive, handle: handle)
        var contextValid = true
        let work = try AtomicAuthorityStageValidation(
            index: f.index, stage: stage,
            archive: f.archive, handle: handle,
            contextCheck: {
                if !contextValid { throw TractandaError("testContextChanged", "Current rights changed.") }
            })
        _ = try work.step(maximumFacts: 1)
        var foreign: OpaquePointer?
        XCTAssertEqual(sqlite3_open(f.root.appendingPathComponent("index.sqlite").path, &foreign), SQLITE_OK)
        defer { sqlite3_close(foreign) }
        XCTAssertEqual(
            sqlite3_exec(
                foreign,
                "UPDATE authority_atomic_support_stage SET payload=payload||' '", nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try work.step(maximumFacts: 1))
        try work.close()
        // The first scenario intentionally changed only disposable SQL. Restore its exact
        // original canonical payload before testing an independent current-context change.
        for (ordinal, value) in try ordered([fact(0), fact(1)]).enumerated() {
            try f.index.execute(
                "UPDATE authority_atomic_support_stage SET payload=? WHERE root=? AND ordinal=?",
                [String(decoding: try JSON.encode(value), as: UTF8.self), id(1), String(ordinal)])
        }
        let next = try AtomicAuthorityStageValidation(
            index: f.index, stage: stage,
            archive: f.archive, handle: handle,
            contextCheck: {
                if !contextValid { throw TractandaError("testContextChanged", "Current rights changed.") }
            })
        defer { try? next.close() }
        while !next.complete { _ = try next.step(maximumFacts: 1) }
        contextValid = false
        XCTAssertThrowsError(try next.withFinalWriter { _ in XCTFail("Changed current rights accepted") })
        XCTAssertFalse(try f.index.hasValidatedAuthorityControl(handle.binding))
    }

    func testFinalComparisonRejectsEmbeddedNULInStagedPayload() throws {
        let f = try Fixture()
        defer { f.remove() }
        let handle = try build(f, facts: [fact(0)])
        let stage = try f.index.stageAtomicControl(archive: f.archive, handle: handle)
        // SQLite text length, not a NUL-terminated C prefix, defines the exact staged bytes.
        let mutation = try f.index.corpusPrepare(
            "UPDATE authority_atomic_support_stage SET payload=payload||char(0)||'forged' WHERE root=?",
            [id(1)])
        defer { sqlite3_finalize(mutation) }
        XCTAssertEqual(sqlite3_step(mutation), SQLITE_DONE)
        XCTAssertThrowsError(
            try f.index.withCanonicalAtomicStage(stage, archive: f.archive, handle: handle) {
                _ in XCTFail("NUL suffix was ignored")
            })
    }

    func testFinalWriterRejectsPreparedStageMutationAndRollsBackOwnedTransaction() throws {
        let f = try Fixture()
        defer { f.remove() }
        let handle = try build(f, facts: [fact(0)])
        let stage = try f.index.stageAtomicControl(archive: f.archive, handle: handle)
        let mutation = try f.index.corpusPrepare(
            "UPDATE authority_atomic_support_stage SET payload=payload||' ' WHERE root=?", [id(1)])
        defer { sqlite3_finalize(mutation) }
        let work = try AtomicAuthorityStageValidation(
            index: f.index, stage: stage,
            archive: f.archive, handle: handle, contextCheck: {})
        while !work.complete { _ = try work.step(maximumFacts: 1) }
        XCTAssertThrowsError(
            try work.withFinalWriter { _ in
                XCTAssertEqual(sqlite3_step(mutation), SQLITE_DONE)
            })
        XCTAssertNil(f.index.activeAtomicControlFinalization)
        XCTAssertFalse(try f.index.hasValidatedAuthorityControl(handle.binding))
        // The fixed owned rollback must leave no open transaction or changed stage prefix.
        XCTAssertNoThrow(try f.index.execute("BEGIN IMMEDIATE"))
        XCTAssertNoThrow(try f.index.execute("ROLLBACK"))
        XCTAssertNoThrow(
            try f.index.withCanonicalAtomicStage(stage, archive: f.archive, handle: handle) { _ in })
    }

}
