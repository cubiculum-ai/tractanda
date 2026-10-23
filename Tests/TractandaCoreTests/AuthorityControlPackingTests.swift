import CTractandaPlatform
import XCTest

@testable import TractandaCore

final class AuthorityControlPackingTests: XCTestCase {
    private typealias Fixture = PeerIntakeStoreTests.Fixture
    private func id(_ n: Int) -> String {
        String(format: "%08x-0000-1000-8000-000000000001", n)
    }
    private func binding(_ n: Int) throws -> AuthorityBinding {
        try .init(recordID: id(n), sha256: String(repeating: "a", count: 64))
    }
    private func deltas(_ count: Int, actor: String = "user:rcfa") throws
        -> [AuthorityStore.DispositionDelta]
    {
        try (0..<count).map { n in
            try .init(
                target: .init(
                    itemID: id(1000 + n), revisionID: id(2000 + n),
                    sha256: String(repeating: "b", count: 64)),
                eligible: n % 2 == 0, actor: actor,
                policyIDs: [id(3), id(4)], causes: [binding(5), binding(6)],
                evidence: binding(3000 + n))
        }
    }
    func testCountOnly128DeltaControlExceedsExactExistingWindow() throws {
        let c = PeerIntakeCoordinator(
            root: FileManager.default.temporaryDirectory,
            ownerUID: tractanda_uid(), storeID: id(1))
        let rows = try deltas(128)
        let parents = try [binding(5), binding(6)]
        let value = ItemValue.object([
            "profile": .text(AuthorityRecord.profile), "recordID": .text(id(7)),
            "storeID": .text(id(1)), "originReplicaID": .text(id(2)),
            "kind": .text("controlCommit"),
            "parentAuthorityIDs": .list(parents.map { .text($0.recordID) }),
            "actorPrincipal": .text("rcfa"), "createdAt": .date("2026-10-23T06:00:00.000Z"),
            "payload": .object([
                "controls": .list(parents.map(\.itemValue)),
                "localParent": .list([parents[0].itemValue]),
                "deltas": .list(rows.map(\.itemValue)), "bootstrap": .list([]),
            ]),
        ])
        let bodyBytes = try JSON.encode(value).count
        let envelopeBytes = try AuthorityRecordCodec.encodedSize(value, recordID: id(7), storeID: id(1))
        print(
            "AUTHORITY_CONTROL_COUNT_ONLY_REPRO bodyBytes=\(bodyBytes) envelopeBytes=\(envelopeBytes) limit=\(AuthorityRecord.maximumBytes) deltas=128"
        )
        XCTAssertGreaterThan(bodyBytes, AuthorityRecord.maximumBytes)
        XCTAssertGreaterThan(envelopeBytes, bodyBytes)
        XCTAssertThrowsError(
            try c.makeControl(
                origin: id(2), actor: "rcfa", localParent: parents[0],
                parents: parents, deltas: rows, bootstrap: nil)
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
            XCTAssertEqual(($0 as? TractandaError)?.message, "Authority record exceeds its byte window.")
        }
    }

    func testCompleteEnvelopePagesPreserveDeltasAndExactParentChain() throws {
        let c = PeerIntakeCoordinator(
            root: FileManager.default.temporaryDirectory,
            ownerUID: tractanda_uid(), storeID: id(1))
        let rows = try deltas(128)
        for includeCauses in [false, true] {
            let previous = try binding(8)
            let head = try binding(5)
            let pages = try c.makeControlPages(
                origin: id(2), actor: "rcfa", localParent: previous,
                fixedParents: [head], deltas: rows, bootstrap: binding(9),
                includingDeltaCauses: includeCauses)
            XCTAssertGreaterThan(pages.count, 1)
            var actual: [AuthorityStore.DispositionDelta] = []
            var current = previous
            for record in pages {
                let encoded = try AuthorityRecordCodec.encode(record)
                XCTAssertLessThanOrEqual(encoded.count, AuthorityRecord.maximumBytes)
                let plan = try AuthorityStore.VerifiedControlPlan(
                    control: AuthorityRecordCodec.decode(encoded))
                XCTAssertEqual(plan.localParent, current)
                let expected = Array(
                    Set([head, current] + (includeCauses ? plan.deltas.flatMap(\.causes) : []))
                )
                .sorted { $0.recordID < $1.recordID }
                XCTAssertEqual(plan.parents, expected)
                XCTAssertLessThanOrEqual(plan.parents.count, 256)
                XCTAssertLessThanOrEqual(plan.deltas.count, 128)
                actual += plan.deltas
                current = plan.binding
            }
            XCTAssertEqual(
                actual, rows, "No eligibility, policy, evidence or cause may be dropped or rewritten")
        }
    }
    private func rawControl(_ rows: [AuthorityStore.DispositionDelta], actor: String) throws -> ItemValue {
        let parents = try [binding(5), binding(6)]
        return .object([
            "profile": .text(AuthorityRecord.profile), "recordID": .text(id(7)),
            "storeID": .text(id(1)), "originReplicaID": .text(id(2)), "kind": .text("controlCommit"),
            "parentAuthorityIDs": .list(parents.map { .text($0.recordID) }),
            "actorPrincipal": .text(actor), "createdAt": .date("2026-10-23T06:00:00.000Z"),
            "payload": .object([
                "controls": .list(parents.map(\.itemValue)), "localParent": .list([parents[1].itemValue]),
                "deltas": .list(rows.map(\.itemValue)), "bootstrap": .list([]),
            ]),
        ])
    }
    func testHeaderOverheadAndEscapedMultibyteJSONDeterminePageBoundary() throws {
        let c = PeerIntakeCoordinator(
            root: FileManager.default.temporaryDirectory,
            ownerUID: tractanda_uid(), storeID: id(1))
        let actor = String(repeating: "é\"\\", count: 24)
        let prefix = try deltas(16, actor: actor)
        var boundary: [AuthorityStore.DispositionDelta]?
        // Find a tiny valid metadata fixture whose body fits but complete MIME envelope does not.
        // Vary bounded policy/cause counts, not disk use or the production limit.
        for policyCount in 0..<32 {
            var lo = 0
            var hi = 256
            var best: [AuthorityStore.DispositionDelta]?
            while lo <= hi {
                let count = (lo + hi) / 2
                let tail = try AuthorityStore.DispositionDelta(
                    target: .init(
                        itemID: id(9000), revisionID: id(9001), sha256: String(repeating: "b", count: 64)),
                    eligible: true, actor: actor, policyIDs: (0..<policyCount).map { id(10000 + $0) },
                    causes: (0..<count).map { try binding(11000 + $0) }, evidence: binding(12000))
                let rows = prefix + [tail]
                let body = try JSON.encode(rawControl(rows, actor: actor)).count
                if body <= AuthorityRecord.maximumBytes {
                    best = rows
                    lo = count + 1
                } else {
                    hi = count - 1
                }
            }
            if let best,
                try AuthorityRecordCodec.encodedSize(
                    rawControl(best, actor: actor),
                    recordID: id(7), storeID: id(1)) > AuthorityRecord.maximumBytes
            {
                boundary = best
                break
            }
        }
        let rows = try XCTUnwrap(boundary)
        let raw = try rawControl(rows, actor: actor)
        let record = try AuthorityRecord(value: raw)
        XCTAssertLessThanOrEqual(try JSON.encode(raw).count, AuthorityRecord.maximumBytes)
        XCTAssertThrowsError(try AuthorityRecordCodec.encode(record)) {
            XCTAssertEqual(
                ($0 as? TractandaError)?.message, "Complete authority envelope exceeds its byte window.")
        }
        let pages = try c.makeControlPages(
            origin: id(2), actor: actor, localParent: binding(6),
            fixedParents: [binding(5)], deltas: rows, bootstrap: nil, includingDeltaCauses: false)
        XCTAssertGreaterThan(pages.count, 1)
        let decoded = try pages.flatMap { record in
            let bytes = try AuthorityRecordCodec.encode(record)
            XCTAssertLessThanOrEqual(bytes.count, AuthorityRecord.maximumBytes)
            return try AuthorityStore.VerifiedControlPlan(control: AuthorityRecordCodec.decode(bytes)).deltas
        }
        XCTAssertEqual(decoded, rows)
    }
    func testSingleUnrepresentableDeltaFailsClosedWithoutTruncation() throws {
        let c = PeerIntakeCoordinator(
            root: FileManager.default.temporaryDirectory,
            ownerUID: tractanda_uid(), storeID: id(1))
        let row = try AuthorityStore.DispositionDelta(
            target: .init(itemID: id(1000), revisionID: id(2000), sha256: String(repeating: "b", count: 64)),
            eligible: true, actor: "rcfa", policyIDs: (0..<256).map { id(10000 + $0) },
            causes: (0..<256).map { try binding(11000 + $0) }, evidence: binding(12000))
        XCTAssertGreaterThan(
            try AuthorityRecordCodec.encodedSize(
                rawControl([row], actor: "rcfa"),
                recordID: id(7), storeID: id(1)), AuthorityRecord.maximumBytes)
        for includeCauses in [false, true] {
            XCTAssertThrowsError(
                try c.makeControlPages(
                    origin: id(2), actor: "rcfa", localParent: nil,
                    fixedParents: [], deltas: [row], bootstrap: nil, includingDeltaCauses: includeCauses)
            ) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
            }
        }
    }
    private func heldOfflineWrites() throws -> (Fixture, [String], Revision) {
        let f = try Fixture()
        let survivor = try f.source.commit(
            .init(
                classID: "Item",
                changes: ["subject": .text("Source-known unaffected item")], operationID: "packing-survivor")
        ).revision
        try f.bootstrap()
        // Withdraw source authority first. The disconnected receiver still has its old
        // admission state while these real-time offline writes are authored after the cut.
        let revoked = try f.source.configureAccess(
            .object([
                "profile": .text(AccessConfiguration.profile),
                "users": .list([.text("admin"), .text("bob")]),
            ]), operationID: "packing-revoke-alice"
        ).revision
        var revisions: [String] = []
        // Same real source-cut revocation scenario as AuthorityCausalStoreTests, with a
        // bounded cohort large enough to overflow count-only control publication.
        for n in 0..<64 {
            if n % 8 == 0 { try f.capacity() }
            let result = try f.receiver.withAccess(forUID: f.receiverAccounts.alice) {
                try f.receiver.commit(
                    .init(
                        classID: "Item", changes: ["subject": .text("Offline \(n)")],
                        operationID: "packing-offline-\(n)"))
            }
            XCTAssertTrue(result.isIndexReady, "Offline fixture root must remain ready: \(result.warnings)")
            let revision = result.revision
            revisions.append(revision.revisionID)
        }
        let result = try f.send(f.packet(f.source.peerMetadataObjects(revisionID: revoked.revisionID)))
        XCTAssertGreaterThan(result.accepted, 0)
        XCTAssertTrue(f.receiver.isCanonicalTrusted)
        try f.capacity()
        return (f, revisions, survivor)
    }
    private func pendingEffects(_ f: Fixture) throws -> [ItemValue] {
        let index = try ItemIndex(
            path: f.receiverRoot.appendingPathComponent("index/items.sqlite").path, create: false)
        defer { index.close() }
        return try index.authorityDispositionEffectPage(limit: 1024).map(\.itemValue)
    }
    private func localWriteAfterHeldEffects(action: CommitRequest.Action) throws {
        let (f, heldIDs, survivor) = try heldOfflineWrites()
        // Normal intake already invokes the same source-cut planner, seals its negative
        // pages and consumes their exact queued effects before it returns ready.
        XCTAssertTrue(try pendingEffects(f).isEmpty)
        do {
            let index = try ItemIndex(
                path: f.receiverRoot.appendingPathComponent("index/items.sqlite").path, create: false)
            defer { index.close() }
            let origin = try XCTUnwrap(f.receiver.replicaID)
            let oldHead = try index.authorityControlHead(originID: origin)
            let planner = PeerIntakeCoordinator(
                root: f.receiverRoot, ownerUID: tractanda_uid(), storeID: f.storeID)
            let pages = try planner.withOperation { () throws -> [AuthorityStore.VerifiedControlPlan] in
                var cursor = oldHead
                var count = 0
                var values: [AuthorityStore.VerifiedControlPlan] = []
                while let next = cursor {
                    count += 1
                    guard count <= 512 else {
                        throw TractandaError("resourceLimit", "Tiny fixture local control walk")
                    }
                    let plan = try AuthorityStore.VerifiedControlPlan(
                        control: planner.control(next, index: index))
                    if plan.deltas.contains(where: { !$0.eligible && heldIDs.contains($0.target.revisionID) })
                    {
                        values.append(plan)
                    }
                    cursor = plan.localParent
                }
                return values.reversed()
            }
            XCTAssertGreaterThan(pages.count, 1)
            XCTAssertTrue(pages.allSatisfy { $0.deltas.count > 1 })
            var prior = try XCTUnwrap(pages.first).localParent
            var rows: [AuthorityStore.DispositionDelta] = []
            for page in pages {
                XCTAssertEqual(page.localParent, prior)
                XCTAssertTrue(page.deltas.allSatisfy { !$0.eligible })
                XCTAssertLessThanOrEqual(page.control.originalBytes.count, AuthorityRecord.maximumBytes)
                rows += page.deltas
                prior = page.binding
            }
            XCTAssertEqual(Set(rows.map { $0.target.revisionID }), Set(heldIDs))
            XCTAssertEqual(rows.count, 64)
            let first = try XCTUnwrap(pages.first).control.record
            let parents = Array(Set((pages.first!.localParent.map { [$0] } ?? []) + rows.flatMap(\.causes)))
                .sorted { $0.recordID < $1.recordID }
            var oldValue = try XCTUnwrap(first.itemValue.map)
            var oldPayload = first.payload
            oldPayload["deltas"] = .list(
                rows.sorted { $0.target.revisionID < $1.target.revisionID }.map(\.itemValue))
            oldPayload["controls"] = .list(parents.map(\.itemValue))
            oldValue["parentAuthorityIDs"] = .list(parents.map { .text($0.recordID) })
            oldValue["payload"] = .object(oldPayload)
            let raw = ItemValue.object(oldValue)
            let oldBody = try JSON.encode(raw).count
            let oldEnvelope = try AuthorityRecordCodec.encodedSize(
                raw, recordID: first.recordID, storeID: f.storeID)
            XCTAssertGreaterThan(oldBody, AuthorityRecord.maximumBytes)
            XCTAssertThrowsError(try AuthorityRecord(value: raw)) {
                XCTAssertEqual(($0 as? TractandaError)?.message, "Authority record exceeds its byte window.")
            }
            print(
                "ACTUAL_PRIVATE_WRITE_CUT action=\(action) deltas=\(rows.count) oldBody=\(oldBody) oldEnvelope=\(oldEnvelope) packedSizes=\(pages.map { $0.control.originalBytes.count }) pendingEffectsAfterSeal=0"
            )
            // A subsequent owning-operation planning failure cannot publish or change the
            // already sealed local head. No queue is fabricated to force this check.
            XCTAssertThrowsError(
                try planner.withOperation(maximumReadBytes: 1) {
                    try planner.prepareSourceCut(index: index, origin: origin, actor: "admin")
                }
            ) { XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit") }
            XCTAssertEqual(try index.authorityControlHead(originID: origin), oldHead)
            XCTAssertTrue(try pendingEffects(f).isEmpty)
        }
        // Revoked Alice cannot author a write or consume the queued negatives.
        XCTAssertThrowsError(
            try f.receiver.withAccess(forUID: f.receiverAccounts.alice) {
                try f.receiver.commit(
                    .init(
                        classID: "Item", changes: ["subject": .text("Denied")],
                        operationID: "packing-denied"))
            }
        ) { XCTAssertEqual(($0 as? TractandaError)?.code, "forbidden") }
        XCTAssertTrue(try pendingEffects(f).isEmpty)
        let request = CommitRequest(
            action: action,
            itemID: action == .revise ? survivor.itemID : nil,
            expectedRevisionID: action == .revise ? survivor.revisionID : nil,
            classID: action == .create ? "Item" : nil,
            changes: ["subject": .text("Small authorized local write")],
            operationID: "packing-local-\(action)")
        let first = try f.receiver.withAccess(forUID: tractanda_uid()) {
            try f.receiver.commit(request)
        }
        XCTAssertTrue(first.isIndexReady, "First write must leave the index ready: \(first.warnings)")
        let retry = try f.receiver.withAccess(forUID: tractanda_uid()) {
            try f.receiver.commit(request)
        }
        XCTAssertEqual(first.revision, retry.revision)
        XCTAssertEqual(
            try f.receiver.withAccess(forUID: tractanda_uid()) {
                try f.receiver.get(first.revision.itemID)
            }, first.revision)
        XCTAssertTrue(
            try pendingEffects(f).isEmpty, "Only existing sealed/validated controls consume exact effects")
        let exported = try f.receiver.peerMetadataObjects(revisionID: first.revision.revisionID)
        let joins = try exported.filter { $0.0.kind == .authority }.compactMap { pair -> AuthorityRecord? in
            let record = try AuthorityRecordCodec.decode(pair.1).record
            return record.kind == .controlCommit && record.originReplicaID == f.receiver.replicaID
                ? record : nil
        }
        XCTAssertGreaterThan(joins.filter { ($0.payload["deltas"]?.array?.count ?? 0) > 1 }.count, 1)
        for record in joins {
            XCTAssertLessThanOrEqual(
                try AuthorityRecordCodec.encode(record).count, AuthorityRecord.maximumBytes)
        }
        do {
            let index = try ItemIndex(
                path: f.receiverRoot.appendingPathComponent("index/items.sqlite").path, create: false)
            defer { index.close() }
            for id in heldIDs {
                XCTAssertEqual(try index.authorityDisposition(id: id)?.disposition, .held)
                XCTAssertNotNil(try index.retainedAuthorityObject(id: id))
            }
        }
        XCTAssertThrowsError(
            try f.receiver.withAccess(forUID: f.receiverAccounts.alice) {
                try f.receiver.get(first.revision.itemID)
            }
        ) { XCTAssertEqual(($0 as? TractandaError)?.code, "forbidden") }
        try f.capacity()
    }
    func testCreateAfterHeldEffectsAndExactOperationRetryPreserveAuthority() throws {
        try localWriteAfterHeldEffects(action: .create)
    }
    func testReviseAfterHeldEffectsAndExactOperationRetryPreserveAuthority() throws {
        try localWriteAfterHeldEffects(action: .revise)
    }
}
