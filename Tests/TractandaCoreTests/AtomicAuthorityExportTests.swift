import CSQLite
import CTractandaPlatform
import XCTest

@testable import TractandaCore

final class AtomicAuthorityExportTests: XCTestCase {
    private func id(_ n: Int) -> String { String(format: "%08x-0000-1000-8000-000000000001", n) }
    private let security = String(repeating: "a", count: 64)

    private final class SQLFixture {
        let root: URL
        var index: ItemIndex
        init(initializeExport: Bool = true) throws {
            try AttachmentFixtureCapacity.requireFree()
            root = try GuardedFixtureDirectory.create(
                prefix: "atomic-export-cursor-", source: #filePath, test: #function)
            index = try ItemIndex(path: root.appendingPathComponent("index.sqlite").path, create: true)
            index.graphReserveBytes = UInt64(AttachmentFixtureCapacity.reserveBytes)
            try index.initializeAuthoritySchema()
            if initializeExport { try index.initializePeerExportSchema() }
        }
        func reopen() throws {
            index.close()
            index = try ItemIndex(path: root.appendingPathComponent("index.sqlite").path, create: false)
            index.graphReserveBytes = UInt64(AttachmentFixtureCapacity.reserveBytes)
        }
        deinit {
            index.close()
            try? FileManager.default.removeItem(at: root)
        }
    }
    private func seed(_ index: ItemIndex, source: String) throws {
        //270 tiny derived rows plus schema/WAL estimate below4MiB; no canonical authority claims.
        try index.execute("BEGIN IMMEDIATE")
        do {
            for (kindNumber, kind) in ["a", "aA", "aa", "atomicPart", "controlParent", "target"].enumerated()
            {
                for ordinal in 0..<45 {
                    let target = id(1000 + kindNumber * 100 + ordinal)
                    let digest = ordinal % 2 == 0 ? "" : String(repeating: "b", count: 64)
                    try index.execute(
                        "INSERT INTO authority_dependencies VALUES(?,?,?,?,?)",
                        [source, kind, target, digest, ""])
                }
            }
            //Same source/target in an unrelated physical-package scope must stay excluded.
            try index.execute(
                "INSERT INTO authority_dependencies VALUES(?,?,?,?,?)",
                [source, "a", id(1000), String(repeating: "c", count: 64), id(90)])
            try index.execute("COMMIT")
        } catch {
            try? index.execute("ROLLBACK")
            throw error
        }
    }
    private func legacyCursors(_ index: ItemIndex, source: String) throws -> [String] {
        let s = try index.corpusPrepare(
            "SELECT DISTINCT kind||':'||target||':'||sha256 FROM authority_dependencies WHERE source=? AND package='' ORDER BY kind||':'||target||':'||sha256",
            [source])
        defer { sqlite3_finalize(s) }
        var values: [String] = []
        while true {
            let status = index.catalogueStep(s)
            if status == SQLITE_DONE { return values }
            guard status == SQLITE_ROW, let text = sqlite3_column_text(s, 0) else {
                throw index.graphSQLiteError()
            }
            values.append(String(cString: text))
        }
    }
    func testTuplePagingPreservesLegacyCursorBytesOrderEmptyDigestsAndReopen() throws {
        let f = try SQLFixture()
        try seed(f.index, source: id(1))
        let expected = try legacyCursors(f.index, source: id(1))
        XCTAssertEqual(expected.count, 270)
        var actual: [String] = []
        var cursor = ""
        var pages = 0
        while true {
            let page = try f.index.peerExportDependencies(id(1), after: cursor, limit: 7)
            if page.isEmpty { break }
            XCTAssertLessThanOrEqual(page.count, 7)
            for ref in page {
                XCTAssertNil(ref.kind)
                if ref.cursor.hasSuffix(":") { XCTAssertNil(ref.digest) }
                actual.append(ref.cursor)
            }
            cursor = page.last!.cursor
            pages += 1
            XCTAssertLessThan(pages, 64)
            if pages == 2 { try f.reopen() }
        }
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(Set(actual).count, actual.count)
    }
    func testTupleSeekUsesBoundedNativeWorkAndRejectsMalformedContinuation() throws {
        let f = try SQLFixture()
        try seed(f.index, source: id(1))
        let cursor = try XCTUnwrap(legacyCursors(f.index, source: id(1)).dropLast().last)
        f.index.graphMaximumVMInstructions = 1500
        let page = try f.index.withCatalogueScanBudget {
            try f.index.peerExportDependencies(id(1), after: cursor, limit: 1)
        }
        XCTAssertEqual(page.count, 1)
        XCTAssertLessThan(f.index.lastCatalogueScanWorkForTesting, 1500)
        for value in [
            String(repeating: ":", count: 2048), "target", "target:" + id(2),
            "target:" + id(2) + ":not-a-digest", "bad-kind:" + id(2) + ":",
            "target:" + id(2) + ":extra:field",
        ] {
            XCTAssertThrowsError(try f.index.peerExportDependencies(id(1), after: value, limit: 1))
        }
        XCTAssertThrowsError(try f.index.peerExportDependencies(id(1), after: "", limit: 0))
        XCTAssertThrowsError(try f.index.peerExportDependencies(id(1), after: "", limit: 129))
        f.index.graphMaximumVMInstructions = 200_000_000
        try f.index.execute(
            "INSERT INTO authority_dependencies VALUES(?,?,?,?,?)", [id(3), "bad:kind", id(4), "", ""])
        XCTAssertThrowsError(try f.index.peerExportDependencies(id(3), after: "", limit: 1))
    }

    func testIndexBuildCapacityFailsBeforeCreationAndWarmFastPathPreservesProof() throws {
        let f = try SQLFixture(initializeExport: false)
        try seed(f.index, source: id(1))
        f.index.graphMaximumTemporaryBytes = 1
        XCTAssertThrowsError(try f.index.initializePeerExportSchema()) { error in
            XCTAssertEqual((error as? TractandaError)?.code, "resourceLimit")
        }
        let check = try f.index.corpusPrepare(
            "SELECT COUNT(*) FROM sqlite_master WHERE name='authority_dependencies_export'")
        XCTAssertEqual(f.index.catalogueStep(check), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(check, 0), 0)
        sqlite3_finalize(check)
        XCTAssertEqual(try legacyCursors(f.index, source: id(1)).count, 270)
        f.index.graphMaximumTemporaryBytes = 256 * 1024 * 1024
        try f.index.validateRecoveryGraph(requireLinearProjection: false)
        let passes = f.index.graphValidationPassesForTesting
        XCTAssertTrue(try f.index.acceptedGraphProofIsCurrent())
        try f.index.initializePeerExportSchema()
        XCTAssertTrue(
            try f.index.acceptedGraphProofIsCurrent(),
            "Fixed derived DDL cannot invalidate accepted graph proof")
        // An existing index must not repeat the history-sized estimate or build-space reservation.
        f.index.graphMaximumTemporaryBytes = 1
        f.index.graphMaximumVMInstructions = 4096
        try f.index.withCatalogueScanBudget { try f.index.initializePeerExportSchema() }
        XCTAssertTrue(try f.index.acceptedGraphProofIsCurrent())
        XCTAssertEqual(f.index.graphValidationPassesForTesting, passes)
    }

    private func source() throws -> (AtomicAuthorityStoreFixture, PeerPackage.Context, Revision) {
        let f = try AtomicAuthorityStoreFixture()
        let origin = try XCTUnwrap(f.source.replicaID)
        let context = try PeerPackage.Context(
            peerID: "atomic-export", storeID: f.storeID,
            configurationDigest: String(repeating: "c", count: 64), permittedOrigins: [origin])
        try f.source.configurePeerIntake(peers: [context])
        try f.activateAndOpen()
        let result = try f.source.commit(
            CommitRequest(
                classID: "Item", changes: ["subject": .text("atomic export")],
                operationID: "atomic-export-source"))
        XCTAssertTrue(result.isIndexReady, result.warnings.joined(separator: "\n"))
        try f.capacity()
        return (f, context, result.revision)
    }
    private func selection(
        _ plan: PeerExportPlan, rootID: String, coordinator: PeerIntakeCoordinator,
        index: ItemIndex, context: PeerPackage.Context
    ) throws -> PeerExportPlan.Handle {
        let boundary = try PeerInventory.capture(context: context, coordinator: coordinator, index: index)
        let handle = try plan.begin(
            planID: UUID.makeVersion1().uuidString.lowercased(),
            packageID: UUID.makeVersion1().uuidString.lowercased(), boundary: boundary,
            limits: .init(maximumPlanBytes: 8 * 1024 * 1024, pageFanout: 8))
        var cursor: PeerInventory.Cursor?
        var selected: PeerInventory.Entry?
        repeat {
            let page = try PeerInventory.page(
                context: context, boundary: boundary, cursor: cursor, limit: 32,
                coordinator: coordinator, index: index, evaluationsAvailable: false, limits: .init(),
                progress: nil)
            if let value = page.entries.first(where: { $0.descriptor.id == rootID }) { selected = value }
            cursor = page.nextCursor
        } while cursor != nil
        _ = try plan.select(handle, entries: [XCTUnwrap(selected)], finish: true)
        return handle
    }
    private func finish(
        _ plan: PeerExportPlan, _ handle: PeerExportPlan.Handle, fixture: AtomicAuthorityStoreFixture
    ) throws {
        for call in 0..<1024 {
            if call % 16 == 0 { try fixture.capacity() }
            let status = try plan.step(
                handle, window: .init(maximumUnits: 4, maximumEdges: 2, maximumReadBytes: 8 * 1024 * 1024))
            if status.manifest != nil { return }
            guard status.unsupported == 0 else {
                throw TractandaError("fixture", "Atomic export has unsupported dependencies")
            }
        }
        throw TractandaError("fixture", "Tiny atomic export did not complete")
    }
    private func descriptors(_ plan: PeerExportPlan, _ handle: PeerExportPlan.Handle) throws -> [PeerPackage
        .Object]
    {
        var result: [PeerPackage.Object] = []
        var after = ""
        while true {
            let page = try plan.objects(handle, afterID: after, limit: 16)
            for slot in page.objects { result.append(try XCTUnwrap(slot.descriptor)) }
            guard result.count < 256 else {
                throw TractandaError("resourceLimit", "Tiny export fixture exceeded its object estimate")
            }
            guard let next = page.nextAfterID else { return result }
            after = next
        }
    }
    private func bytes(
        _ plan: PeerExportPlan, _ handle: PeerExportPlan.Handle, _ descriptor: PeerPackage.Object
    ) throws -> Data {
        var result = Data()
        while result.count < descriptor.length {
            let chunk = try plan.read(handle, object: descriptor, offset: result.count, maximumBytes: 4096)
            guard !chunk.bytes.isEmpty else { throw TractandaError("fixture", "Export failed to advance") }
            result.append(chunk.bytes)
        }
        XCTAssertEqual(result.count, descriptor.length)
        XCTAssertEqual(AuthorityRecordCodec.sha256(result), descriptor.sha256)
        return result
    }

    func testRealAtomicRootExportsCompleteClosureAndPhysicalPartNeverBecomesCut() throws {
        let (f, context, revision) = try source()
        let index = try ItemIndex(
            path: f.sourceRoot.appendingPathComponent("index/items.sqlite").path, create: false)
        defer { index.close() }
        let coordinator = PeerIntakeCoordinator(
            root: f.sourceRoot, ownerUID: tractanda_uid(), storeID: f.storeID)
        let head = try XCTUnwrap(index.authorityControlHead(originID: XCTUnwrap(f.source.replicaID)))
        XCTAssertTrue(try index.isAcceptedAtomicControl(head))
        XCTAssertEqual(try f.source.get(revision.itemID).revisionID, revision.revisionID)
        let currentState = try f.source.itemState(revision.itemID)
        let proof = try f.source.atomicGraphProofForTesting()
        XCTAssertTrue(proof.current)
        let projection = try XCTUnwrap(index.currentProjection(itemID: revision.itemID))
        XCTAssertEqual(projection.state, currentState)
        XCTAssertTrue(try f.source.atomicGraphProofForTesting().current)
        let plan = PeerExportPlan(
            coordinator: coordinator, index: index, context: context, securityBinding: security)
        let handle = try selection(
            plan, rootID: head.recordID, coordinator: coordinator, index: index, context: context)
        XCTAssertTrue(
            try f.source.atomicGraphProofForTesting().current,
            "Export schema creation must preserve the real Store graph proof")
        try finish(plan, handle, fixture: f)
        XCTAssertTrue(try f.source.atomicGraphProofForTesting().current)
        XCTAssertEqual(try f.source.atomicGraphProofForTesting().validationPasses, proof.validationPasses)
        XCTAssertEqual(try index.currentProjection(itemID: revision.itemID)?.state, projection.state)
        XCTAssertEqual(
            try index.currentProjection(itemID: revision.itemID)?.representativeDigest,
            projection.representativeDigest)
        let objects = try descriptors(plan, handle)
        let ids = Set(objects.map(\.id))
        XCTAssertTrue(ids.contains(head.recordID))
        XCTAssertTrue(
            ids.contains(revision.revisionID),
            "Accepted support targets must travel through normalized dependencies")
        var part: PeerPackage.Object?
        for descriptor in objects where descriptor.kind == .authority {
            let original = try CanonicalAuthorityOriginal(bytes(plan, handle, descriptor))
            for child in try original.physicalChildren() {
                XCTAssertTrue(ids.contains(child.binding.recordID))
            }
            if case .atomic(let record) = original.payload, record.kind != .atomicControl {
                let binding = try AuthorityBinding(recordID: descriptor.id, sha256: descriptor.sha256)
                XCTAssertFalse(
                    try index.hasValidatedAuthorityControl(binding),
                    "Physical framing is never an accepted cut")
                if record.kind == .atomicControlPart { part = descriptor }
            }
        }
        let physical = try XCTUnwrap(part)
        let partPlan = PeerExportPlan(
            coordinator: coordinator, index: index, context: context, securityBinding: security)
        let partHandle = try selection(
            partPlan, rootID: physical.id, coordinator: coordinator, index: index, context: context)
        try finish(partPlan, partHandle, fixture: f)
        XCTAssertEqual(
            try descriptors(partPlan, partHandle).map(\.id), [physical.id],
            "A part's controlID must not manufacture a causal dependency to its root")
        XCTAssertEqual(try index.authorityControlHead(originID: XCTUnwrap(f.source.replicaID)), head)
        try f.capacity()
    }
    func testConflictingAcceptedDependencyHashCannotSealAtomicExport() throws {
        let (f, context, revision) = try source()
        let index = try ItemIndex(
            path: f.sourceRoot.appendingPathComponent("index/items.sqlite").path, create: false)
        defer { index.close() }
        let coordinator = PeerIntakeCoordinator(
            root: f.sourceRoot, ownerUID: tractanda_uid(), storeID: f.storeID)
        let head = try XCTUnwrap(index.authorityControlHead(originID: XCTUnwrap(f.source.replicaID)))
        try index.execute(
            "UPDATE authority_dependencies SET sha256=? WHERE source=? AND kind='atomicSupportTarget' AND target=? AND package=''",
            [String(repeating: "f", count: 64), head.recordID, revision.revisionID])
        let plan = PeerExportPlan(
            coordinator: coordinator, index: index, context: context, securityBinding: security)
        let handle = try selection(
            plan, rootID: head.recordID, coordinator: coordinator, index: index, context: context)
        XCTAssertThrowsError(try finish(plan, handle, fixture: f)) { error in
            XCTAssertEqual((error as? TractandaError)?.code, "peerObjectCollision")
        }
        XCTAssertNil(try plan.manifest(handle))
        XCTAssertEqual(try index.authorityControlHead(originID: XCTUnwrap(f.source.replicaID)), head)
        try f.capacity()
    }
}
