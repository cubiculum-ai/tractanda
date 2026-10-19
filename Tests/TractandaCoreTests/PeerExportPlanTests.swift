import CTractandaPlatform
import XCTest

@testable import TractandaCore

final class PeerExportPlanTests: XCTestCase {
    private final class Fixture {
        let root: URL
        let index: ItemIndex
        let coordinator: PeerIntakeCoordinator
        let context: PeerPackage.Context
        let storeID: String
        let origin: String
        let binding = String(repeating: "a", count: 64)
        static func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }
        init() throws {
            try AttachmentFixtureCapacity.requireFree()
            //270 tiny canonical records, private receipts and bounded step events: estimate24MiB.
            guard UInt64(24 * 1024 * 1024) <= AttachmentFixtureCapacity.fixtureCapBytes else {
                throw TractandaError("resourceLimit", "Fixture estimate")
            }
            root = (try GuardedFixtureDirectory.parent()).appendingPathComponent(
                "peer-export-" + (try Self.id()))
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            storeID = try Self.id()
            origin = try Self.id()
            context = try .init(
                peerID: "fixture", storeID: storeID, configurationDigest: String(repeating: "b", count: 64),
                permittedOrigins: [origin])
            coordinator = .init(root: root, ownerUID: tractanda_uid(), storeID: storeID)
            try AuthorityStore.writeConfiguration(
                .init(profile: "tractanda.peer-configuration.v1", peers: [context], bootstrap: nil),
                root: root, files: coordinator.journal.files)
            index = try ItemIndex(path: root.appendingPathComponent("index.sqlite").path, create: true)
            index.graphReserveBytes = UInt64(AttachmentFixtureCapacity.reserveBytes)
            try index.initializeAuthoritySchema()
            try index.initializeAuthorityControlSchema()
            try index.initializeAuthorityReviewSchema()
            try index.initializePeerLifecycleSchema()
        }
        deinit {
            index.close()
            try? FileManager.default.removeItem(at: root)
        }
        func capacity() throws {
            try AttachmentFixtureCapacity.requireFree(at: root)
            var count: UInt64 = 0
            guard
                let walk = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: [.fileSizeKey])
            else { throw TractandaError("resourceLimit", "Fixture storage unavailable") }
            for case let file as URL in walk {
                count += UInt64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                guard count < AttachmentFixtureCapacity.fixtureCapBytes else {
                    throw TractandaError("resourceLimit", "Fixture cap")
                }
            }
        }
        func record(id: String? = nil, parent: AuthorityRecordCodec.Verified? = nil) throws
            -> AuthorityRecordCodec.Verified
        {
            let refs =
                try parent.map {
                    [try AuthorityBinding(recordID: $0.record.recordID, sha256: $0.sha256).itemValue]
                } ?? []
            let record = try AuthorityRecord(
                recordID: id ?? Self.id(), storeID: storeID, originReplicaID: origin,
                kind: .controlCommit, parentAuthorityIDs: parent.map { [$0.record.recordID] } ?? [],
                actorPrincipal: "fixture", createdAt: "2026-10-15T10:00:00.000Z",
                payload: [
                    "controls": .list(refs), "localParent": .list([]), "deltas": .list([]),
                    "bootstrap": .list([]),
                ])
            return try AuthorityRecordCodec.decode(AuthorityRecordCodec.encode(record))
        }
        @discardableResult
        func add(_ record: AuthorityRecordCodec.Verified) throws -> PeerPackage.Object {
            try capacity()
            let object = PeerPackage.Object(
                kind: .authority, id: record.record.recordID, length: record.originalBytes.count,
                sha256: record.sha256)
            let manifest = try coordinator.stageObjects(
                [(object, record.originalBytes)], context: context, packageID: Self.id())
            try coordinator.journal.prepare(
                .init(
                    packageID: manifest.packageID,
                    manifestDigest: AuthorityRecordCodec.sha256(JSON.encode(manifest)), context: context,
                    contextToken: "fixture", arrivalMinute: "2026/10/15/10/00"))
            try coordinator.journal.seal(manifest.packageID)
            try coordinator.retainSealed(
                manifest.packageID, index: index, applyAssessment: false, allowReviewClosure: true)
            try coordinator.journal.applied(manifest.packageID)
            return object
        }
        func plan() -> PeerExportPlan {
            .init(coordinator: coordinator, index: index, context: context, securityBinding: binding)
        }
        func selection(_ plan: PeerExportPlan, ids: Set<String>? = nil, fanout: Int = 8) throws
            -> PeerExportPlan.Handle
        {
            let boundary = try PeerInventory.capture(context: context, coordinator: coordinator, index: index)
            let handle = try plan.begin(
                planID: Self.id(), packageID: Self.id(), boundary: boundary, limits: .init(pageFanout: fanout)
            )
            var cursor: PeerInventory.Cursor?
            repeat {
                let page = try PeerInventory.page(
                    context: context, boundary: boundary, cursor: cursor, limit: 64, coordinator: coordinator,
                    index: index, evaluationsAvailable: false, limits: .init(), progress: nil)
                _ = try plan.select(
                    handle, entries: page.entries.filter { ids == nil || ids!.contains($0.descriptor.id) },
                    finish: page.nextCursor == nil)
                cursor = page.nextCursor
            } while cursor != nil
            return handle
        }
        func finish(_ plan: PeerExportPlan, _ handle: PeerExportPlan.Handle, maximumCalls: Int = 2000) throws
            -> PeerPackage.Manifest
        {
            for call in 0..<maximumCalls {
                if call % 32 == 0 { try capacity() }
                let state = try plan.step(handle, window: .init(maximumUnits: 3, maximumEdges: 1))
                if let manifest = state.manifest { return manifest }
                guard state.unsupported == 0 else {
                    throw TractandaError(
                        "testBlocked", "Missing\(state.missing) unsupported\(state.unsupported)")
                }
            }
            throw TractandaError("testTimeout", "Export did not finish")
        }
    }
    private func code(_ expected: String, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body()) { XCTAssertEqual(($0 as? TractandaError)?.code, expected) }
    }
    func testMoreThan256RootsAndDeepChainUseTinyStepsAndHierarchicalPages() throws {
        let f = try Fixture()
        var parent: AuthorityRecordCodec.Verified?
        var originals: Set<String> = []
        for _ in 0..<270 {
            let record = try f.record(parent: parent)
            _ = try f.add(record)
            originals.insert(record.record.recordID)
            parent = record
        }
        let plan = f.plan()
        let handle = try f.selection(plan)
        XCTAssertEqual(try plan.status(handle).objects, 270)
        let manifest = try f.finish(plan, handle)
        var pending = [manifest.root]
        var seen: Set<String> = []
        var found: Set<String> = []
        var indexCount = 0
        while let descriptor = pending.popLast() {
            XCTAssertTrue(seen.insert(descriptor.id).inserted)
            let chunk = try f.plan().read(
                handle, object: descriptor, offset: 0, maximumBytes: PeerPackage.maximumChunkBytes)
            if descriptor.kind == .index {
                indexCount += 1
                let page = try PeerPackage.decode(PeerPackage.Page.self, chunk.bytes)
                XCTAssertLessThanOrEqual(page.objects.count + page.children.count, 8)
                pending += page.objects + page.children
            } else {
                found.insert(descriptor.id)
            }
        }
        XCTAssertGreaterThan(indexCount, 2)
        XCTAssertEqual(found, originals)
        XCTAssertEqual(try f.plan().status(handle).objects, 270)
        let tip = try XCTUnwrap(parent).record.recordID
        let deep = f.plan()
        let deepHandle = try f.selection(deep, ids: [tip])
        XCTAssertEqual(try deep.status(deepHandle).objects, 1)
        _ = try f.finish(deep, deepHandle)
        XCTAssertEqual(try deep.status(deepHandle).objects, 270)
        var after = ""
        var rootIDs: Set<String> = []
        repeat {
            let page = try deep.objects(deepHandle, afterID: after)
            rootIDs.formUnion(page.objects.filter(\.root).map(\.id))
            guard let next = page.nextAfterID else { break }
            after = next
        } while true
        XCTAssertEqual(rootIDs, [tip])
        try f.capacity()
    }
    func testMissingExactParentCanArriveAfterFiniteRootSelection() throws {
        let f = try Fixture()
        let parent = try f.record()
        let child = try f.record(parent: parent)
        _ = try f.add(child)
        let plan = f.plan()
        let handle = try f.selection(plan)
        var blocked = false
        for _ in 0..<16 {
            let status = try plan.step(handle, window: .init(maximumUnits: 2, maximumEdges: 1))
            if status.missing > 0 {
                blocked = true
                break
            }
        }
        XCTAssertTrue(blocked)
        XCTAssertNil(try plan.manifest(handle))
        _ = try f.add(parent)
        _ = try f.finish(f.plan(), handle)
        XCTAssertEqual(try f.plan().status(handle).objects, 2)
        let slots = try f.plan().objects(handle).objects
        XCTAssertEqual(Set(slots.filter(\.root).map(\.id)), [child.record.recordID])
        XCTAssertEqual(Set(slots.map(\.id)), [child.record.recordID, parent.record.recordID])
    }
    func testCompetingExactDependencyDigestRejectsInsteadOfSelectingAnAlternative() throws {
        let f = try Fixture()
        let parent = try f.record()
        _ = try f.add(parent)
        let wrong = try AuthorityBinding(
            recordID: parent.record.recordID, sha256: String(repeating: "c", count: 64))
        let child = try AuthorityRecord(
            recordID: Fixture.id(), storeID: f.storeID, originReplicaID: f.origin, kind: .controlCommit,
            parentAuthorityIDs: [parent.record.recordID],
            actorPrincipal: "fixture", createdAt: "2026-10-15T10:00:00.000Z",
            payload: [
                "controls": .list([wrong.itemValue]), "localParent": .list([]), "deltas": .list([]),
                "bootstrap": .list([]),
            ])
        _ = try f.add(AuthorityRecordCodec.decode(AuthorityRecordCodec.encode(child)))
        let plan = f.plan()
        let handle = try f.selection(plan, ids: [child.recordID])
        code("peerObjectCollision") {
            for _ in 0..<8 { _ = try plan.step(handle, window: .init(maximumUnits: 3, maximumEdges: 1)) }
        }
        XCTAssertNil(try plan.manifest(handle))
    }
    func testRetirementMembershipIsTraversedButUnsupportedAdmissionBlocksSeal() throws {
        let f = try Fixture()
        let original = try f.record()
        _ = try f.add(original)
        let page = try AuthorityRecord(
            recordID: Fixture.id(), storeID: f.storeID, originReplicaID: f.origin,
            kind: .originRetirementPage,
            actorPrincipal: "fixture", createdAt: "2026-10-15T10:00:00.000Z",
            payload: [
                "operationID": .text(Fixture.id()), "previous": .list([]),
                "members": .list([
                    PeerLifecycle.Member(
                        objectID: original.record.recordID, sha256: original.sha256, kind: .authority,
                        eligible: false
                    ).value
                ]),
            ])
        _ = try f.add(AuthorityRecordCodec.decode(AuthorityRecordCodec.encode(page)))
        let plan = f.plan()
        let handle = try f.selection(plan, ids: [page.recordID])
        for _ in 0..<24 { _ = try plan.step(handle, window: .init(maximumUnits: 2, maximumEdges: 1)) }
        XCTAssertEqual(try plan.status(handle).unsupported, 1)
        XCTAssertNil(try plan.manifest(handle))
        let slots = try plan.objects(handle).objects
        XCTAssertEqual(Set(slots.map(\.id)), [original.record.recordID, page.recordID])
        XCTAssertEqual(
            slots.first { $0.id == page.recordID }?.reason, "unsupportedHistoricalRetirementAdmission")
    }
    func testNonAcceptDecisionCannotSealAsSupportedAtomicReview() throws {
        let f = try Fixture()
        let evidence = try f.record()
        _ = try f.add(evidence)
        let target = ItemValue.object([
            "itemID": .text(try Fixture.id()), "revisionID": .text(try Fixture.id()),
            "sha256": .text(String(repeating: "c", count: 64)),
        ])
        let record = try AuthorityRecord(
            recordID: Fixture.id(), storeID: f.storeID, originReplicaID: f.origin,
            kind: .reviewDecision, actorPrincipal: "fixture", createdAt: "2026-10-15T10:00:00.000Z",
            payload: [
                "target": target,
                "evidence": try AuthorityBinding(recordID: evidence.record.recordID, sha256: evidence.sha256)
                    .itemValue,
                "holds": .list([]), "decisionFrontier": .list([]),
                "reason": .text("reject remains audit only"),
                "decision": .text("reject"), "administrationPolicies": .list([]), "itemPolicies": .list([]),
            ])
        let descriptor = try f.add(AuthorityRecordCodec.decode(AuthorityRecordCodec.encode(record)))
        let plan = f.plan()
        let handle = try f.selection(plan, ids: [record.recordID])
        for _ in 0..<24 { _ = try plan.step(handle, window: .init(maximumUnits: 2, maximumEdges: 1)) }
        XCTAssertEqual(try plan.status(handle).unsupported, 1)
        XCTAssertNil(try plan.manifest(handle))
        XCTAssertEqual(
            try plan.objects(handle).objects.first { $0.id == record.recordID }?.reason,
            "unsupportedForeignNonAtomicReview")
        code("peerExportUnsealed") {
            _ = try plan.read(
                handle, object: descriptor, offset: 0, maximumBytes: 1024,
                receiverKnown: descriptor)
        }
    }
    func testProtectedReviewIsExplicitAndKnownClaimCannotBypassIncompleteClosure() throws {
        let f = try Fixture()
        let evidence = try f.record()
        _ = try f.add(evidence)
        let target = ItemValue.object([
            "itemID": .text(try Fixture.id()), "revisionID": .text(try Fixture.id()),
            "sha256": .text(String(repeating: "c", count: 64)),
        ])
        let hold = try AuthorityRecord(
            recordID: Fixture.id(), storeID: f.storeID, originReplicaID: f.origin, kind: .reviewHold,
            actorPrincipal: "fixture", createdAt: "2026-10-15T10:00:00.000Z",
            payload: [
                "target": target,
                "evidence": try AuthorityBinding(recordID: evidence.record.recordID, sha256: evidence.sha256)
                    .itemValue,
                "revocations": .list([target]), "decisionFrontier": .list([]),
                "reason": .text("held foreign review"),
            ])
        let descriptor = try f.add(AuthorityRecordCodec.decode(AuthorityRecordCodec.encode(hold)))
        let plan = f.plan()
        let handle = try f.selection(plan, ids: [hold.recordID])
        for _ in 0..<24 { _ = try plan.step(handle, window: .init(maximumUnits: 2, maximumEdges: 1)) }
        XCTAssertEqual(try plan.status(handle).unsupported, 1)
        XCTAssertGreaterThan(try plan.status(handle).missing, 0)
        XCTAssertNil(try plan.manifest(handle))
        XCTAssertEqual(
            try plan.objects(handle).objects.first { $0.id == hold.recordID }?.reason,
            "unsupportedForeignProtectedReviewHold")
        code("peerExportUnsealed") {
            _ = try plan.read(
                handle, object: descriptor, offset: 0, maximumBytes: 1024, receiverKnown: descriptor)
        }
    }

}
