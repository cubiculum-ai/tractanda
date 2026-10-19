import CSQLite
import Crypto
import XCTest

@testable import TractandaCore

final class AuthorityReviewIndexTests: XCTestCase {
    private struct Item {
        let original: AuthorityRevision
        let row: ItemIndex.CatalogueRow
        var id: String { original.revision.revisionID }
        var target: AuthorityStore.Target {
            try! .init(itemID: row.itemID, revisionID: id, sha256: original.sha256)
        }
    }
    private final class Fixture {
        let root: URL
        let index: ItemIndex
        let origin = try! UUID.makeVersion1().uuidString.lowercased()
        let store = try! UUID.makeVersion1().uuidString.lowercased()
        let package = try! UUID.makeVersion1().uuidString.lowercased()
        static let cap: UInt64 = 8 * 1024 * 1024
        init() throws {
            try AttachmentFixtureCapacity.requireFree()
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "authority-review-" + Identifier.make())
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            index = try ItemIndex(path: root.appendingPathComponent("index.sqlite").path, create: true)
            index.graphReserveBytes = UInt64(AttachmentFixtureCapacity.reserveBytes)
            try index.validateRecoveryGraph(requireLinearProjection: false)
            try index.initializeAuthoritySchema()
            try index.initializeAuthorityControlSchema()
            try index.initializeAuthorityReviewSchema()
        }
        deinit {
            index.close()
            try? FileManager.default.removeItem(at: root)
        }
        func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }
        func transaction<T>(_ body: () throws -> T) throws -> T {
            try index.execute("BEGIN IMMEDIATE")
            do {
                let result = try body()
                try index.execute("COMMIT")
                return result
            } catch {
                try? index.execute("ROLLBACK")
                throw error
            }
        }
        func write(_ bytes: Data, path: String) throws -> FileMetadata {
            try AttachmentFixtureCapacity.requireFree(at: root)
            var estimate = UInt64(bytes.count + 8192)
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
            else { throw TractandaError("resourceLimit", "Fixture size unavailable.") }
            while let u = e.nextObject() as? URL {
                estimate += UInt64(try u.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            }
            guard estimate <= Self.cap else { throw TractandaError("resourceLimit", "Fixture cap exceeded.") }
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
            return try FileMetadata.read(at: url)
        }
        func item(
            parent: Item? = nil, deleted: Bool = false, subject: String = "base", resolution: Bool = false,
            additionalParents: [String] = [], badPayload: Bool = false, addressed: [String]? = nil,
            changes: [String: ItemValue] = [:], reviewedFrontier: [String]? = nil
        ) throws -> Item {
            var fields =
                try parent?.original.revision.fields ?? [
                    "itemID": .text(id()), "classID": .text("Item"), "schemaVersion": .integer(1),
                    "createdAt": .date("2026-10-14T12:00:00.000Z"),
                ]
            let rid = try id()
            fields["revisionID"] = .text(rid)
            fields["actor"] = .text("user:fixture")
            fields["operationID"] = .text(try id())
            fields["requestIdentity"] = .text("review-fixture")
            fields["subject"] = .text(subject)
            fields["isDeleted"] = .boolean(deleted)
            fields["modifiedAt"] = .date(
                try parent.map {
                    try RevisionPublicationClock.after(
                        [$0.original.revision.modifiedAt], now: { "2026-10-14T12:00:00.000Z" })
                } ?? "2026-10-14T12:00:00.000Z")
            for (key, value) in changes { fields[key] = value }
            fields.removeValue(forKey: "revisionAncestry")
            let parents = Array(Set((parent.map { [$0.id] } ?? []) + additionalParents)).sorted()
            if parents.count == 1 {
                fields["supersedes"] = .text(parents[0])
            } else {
                fields.removeValue(forKey: "supersedes")
            }
            let writes =
                addressed
                ?? (parent == nil
                    ? fields.keys.filter { !RevisionMerge.managedFields.contains($0) }.sorted()
                    : (badPayload ? ["isDeleted"] : ["isDeleted", "subject"]))
            fields["revisionAncestry"] = try RevisionProvenance(
                kind: resolution ? .resolution : .authored, originReplicaID: origin, parents: parents,
                writtenFields: writes, unsetFields: [],
                frontier: resolution ? (reviewedFrontier ?? [parent!.id]) : []
            ).itemValue
            let value = try Revision(fields: fields, formatVersion: 2)
            let original = try AuthorityRevision(originalBytes: RecordCodec.encode(value))
            let path = "items/2026/10/14/12/00/" + value.itemID + "/" + rid + ".tractanda"
            let metadata = try write(original.originalBytes, path: path)
            let row = ItemIndex.CatalogueRow(
                revisionID: rid, itemID: value.itemID, path: path, parentID: value.supersedes,
                actor: "user:fixture", operationID: fields["operationID"]!.string!, size: metadata.size,
                inode: metadata.inode, uid: metadata.uid, mode: metadata.mode,
                modificationSeconds: metadata.modificationSeconds,
                modificationNanoseconds: metadata.modificationNanoseconds,
                digest: Data(SHA256.hash(data: original.originalBytes)),
                createdAt: fields["createdAt"]!.dateString!, modifiedAt: value.modifiedAt,
                provenance: try value.provenance)
            try index.retainAuthorityObject(
                .init(
                    descriptor: .init(
                        kind: .item, id: rid, length: original.originalBytes.count, sha256: original.sha256),
                    path: path, packageID: package, peerID: "fixture",
                    configurationDigest: String(repeating: "a", count: 64), permittedOrigin: true),
                revision: original, authority: nil)
            return .init(original: original, row: row)
        }
        func record(
            _ kind: AuthorityRecord.Kind, payload: [String: ItemValue], parents: [AuthorityBinding] = [],
            issuer: String? = nil
        ) throws -> AuthorityRecordCodec.Verified {
            let r = try AuthorityRecord(
                recordID: id(), storeID: store, originReplicaID: issuer ?? origin, kind: kind,
                parentAuthorityIDs: Array(Set(parents.map(\.recordID))).sorted(), actorPrincipal: "fixture",
                createdAt: "2026-10-14T12:00:00.000Z", payload: payload)
            let original = try AuthorityRecordCodec.decode(AuthorityRecordCodec.encode(r))
            let path = "authority/" + r.recordID + ".tractanda"
            _ = try write(original.originalBytes, path: path)
            try index.retainAuthorityObject(
                .init(
                    descriptor: .init(
                        kind: .authority, id: r.recordID, length: original.originalBytes.count,
                        sha256: original.sha256), path: path, packageID: package, peerID: "fixture",
                    configurationDigest: String(repeating: "a", count: 64), permittedOrigin: true),
                revision: nil, authority: original)
            return original
        }
        func evidence(_ item: Item, cut: AuthorityBinding, decision: AuthorityBinding? = nil) throws
            -> AuthorityRecordCodec.Verified
        {
            let p = try item.original.revision.provenance!
            return try record(
                .authoredEvidence,
                payload: [
                    "target": item.target.itemValue, "sourceControl": .list([cut.itemValue]),
                    "parents": .list(p.parents.map(ItemValue.text)),
                    "frontier": .list(p.parents.map(ItemValue.text)),
                    "itemPolicies": .list([]), "admissionPolicies": .list([]), "principal": .text("fixture"),
                    "sourceUID": .integer(0), "groups": .object([:]), "aliases": .object([:]),
                    "rights": .list([.text("write")]), "evaluated": .boolean(true),
                    "intent": .object([
                        "writtenFields": .list(p.writtenFields.map(ItemValue.text)), "unsetFields": .list([]),
                    ]),
                    "acceptedAuthority": .list(decision.map { [$0.itemValue] } ?? []),
                ], parents: [cut] + (decision.map { [$0] } ?? []))
        }
        func control(parents: [AuthorityBinding] = [], effects: [AuthorityStore.DispositionDelta]) throws
            -> AuthorityStore.VerifiedControlPlan
        {
            let r = try record(
                .controlCommit,
                payload: [
                    "controls": .list(parents.map(\.itemValue)),
                    "localParent": .list(parents.first.map { [$0.itemValue] } ?? []),
                    "deltas": .list(
                        effects.sorted { $0.target.revisionID < $1.target.revisionID }.map(\.itemValue)),
                    "bootstrap": .list([]),
                ], parents: parents)
            return try .init(control: r)
        }
        func initial(permissions: ItemValue? = nil, classID: String = "Item") throws -> (
            Item, AuthorityStore.VerifiedControlPlan
        ) {
            var changes = permissions.map { ["permissions": $0] } ?? [:]
            changes["classID"] = .text(classID)
            let a = try item(changes: changes)
            try index.setAuthorityDisposition(
                id: a.id, evaluation: .init(disposition: .eligible, reason: "fixture"))
            try index.appendValidatedPeer(row: a.row, revision: a.original, parent: nil)
            let cut = try control(effects: [
                .init(target: a.target, eligible: true, actor: "fixture", policyIDs: [])
            ])
            try index.retainValidatedControl(cut)
            return (a, cut)
        }
        func plan(
            base: Item, initial: AuthorityStore.VerifiedControlPlan, badPayload: Bool = false,
            policies: [Item]? = nil, otherParents: [Item] = [], resolutionChanges: [String: ItemValue] = [:]
        ) throws
            -> (AuthorityStore.VerifiedReviewPlan, Item, Item)
        {
            let b = try item(parent: base, deleted: true, subject: "held")
            let be = try evidence(b, cut: initial.binding)
            let eb = try AuthorityBinding(recordID: be.record.recordID, sha256: be.sha256)
            try index.setAuthorityDisposition(
                id: b.id, evaluation: .init(disposition: .held, reason: "stale authority"))
            let cut = try control(
                parents: [initial.binding],
                effects: [
                    .init(target: b.target, eligible: false, actor: "fixture", policyIDs: [], evidence: eb)
                ])
            try index.retainValidatedControl(cut)
            let reviewed = (policies ?? [base]).sorted { $0.id < $1.id }
            let extraWrites =
                resolutionChanges.isEmpty
                ? nil : Array(Set(["isDeleted", "subject"] + Array(resolutionChanges.keys))).sorted()
            let c = try item(
                parent: b, subject: "resolved", resolution: true,
                additionalParents: [base.id] + otherParents.map(\.id),
                badPayload: badPayload, addressed: extraWrites, changes: resolutionChanges,
                reviewedFrontier: ([b.id] + otherParents.map(\.id)).sorted())
            let d = try record(
                .reviewDecision,
                payload: [
                    "target": b.target.itemValue, "evidence": eb.itemValue, "holds": .list([]),
                    "decisionFrontier": .list([]),
                    "decision": .text("accept"), "administrationPolicies": .list([]),
                    "itemPolicies": .list(reviewed.map { $0.target.itemValue }),
                    "reason": .text("explicit fresh lifecycle choice"),
                    "sourceControl": .list([cut.binding.itemValue]),
                    "resolution": .list([c.target.itemValue]), "controlHolds": .list([cut.binding.itemValue]),
                ], parents: [cut.binding])
            let event = try AuthorityStore.VerifiedReviewEvent(record: d, parents: [])
            let ce = try evidence(c, cut: cut.binding, decision: event.binding)
            let ecb = try AuthorityBinding(recordID: ce.record.recordID, sha256: ce.sha256)
            let post = try control(
                parents: [cut.binding],
                effects: [
                    .init(
                        target: b.target, eligible: true, actor: "fixture", policyIDs: [base.id],
                        causes: [event.binding], evidence: eb),
                    .init(
                        target: c.target, eligible: true, actor: "fixture", policyIDs: [base.id],
                        causes: [event.binding], evidence: ecb),
                ])
            let p = try AuthorityStore.VerifiedReviewPlan(
                event: event, held: b.original, heldRow: b.row, resolution: c.original, evidence: ce,
                control: post, policyFrontier: reviewed.map(\.target), operationID: c.row.operationID)
            return (p, b, c)
        }
        func locallyAcceptedAuthored(
            parent: Item, source: AuthorityBinding, selected: Bool = true,
            addressed: [String] = ["subject"], changes: [String: ItemValue] = [:]
        ) throws -> (Item, AuthorityRecordCodec.Verified, AuthorityStore.VerifiedControlPlan) {
            let item = try self.item(
                parent: parent, subject: "locally accepted G", addressed: addressed, changes: changes)
            let evidence = try self.evidence(item, cut: source)
            let binding = try AuthorityBinding(recordID: evidence.record.recordID, sha256: evidence.sha256)
            try index.setAuthorityDisposition(
                id: item.id,
                evaluation: .init(
                    disposition: .eligible, reason: "sealed selected fixture",
                    evidenceID: selected ? binding.recordID : nil,
                    evidenceDigest: selected ? binding.sha256 : nil,
                    evidencePackageID: selected ? package : nil))
            let positive = try control(
                parents: [source],
                effects: [
                    .init(
                        target: item.target, eligible: true, actor: "fixture", policyIDs: [parent.id],
                        evidence: binding)
                ])
            try index.retainValidatedControl(positive)
            try index.retainLocalAuthorityAcceptance(positive)
            return (item, evidence, positive)
        }
        func load(_ row: ItemIndex.CatalogueRow) throws -> PooledCanonicalRecord {
            try .read(row: row, root: root, ownerUID: FileMetadata.read(at: root).uid)
        }
        func hold(_ p: AuthorityStore.VerifiedReviewPlan, parents: [AuthorityBinding]) throws
            -> AuthorityRecordCodec.Verified
        {
            try record(
                .reviewHold,
                payload: [
                    "target": p.event.target.itemValue, "evidence": p.event.evidence.itemValue,
                    "revocations": .list([p.event.target.itemValue]),
                    "decisionFrontier": .list(parents.map { .text($0.recordID) }),
                    "reason": .text("new hold"),
                ], parents: parents)
        }
    }
    private func code(
        _ expected: String, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(($0 as? TractandaError)?.code, expected, file: file, line: line)
        }
    }
    func testApprovalWithoutReviewSchemaIsUnknownWithoutCreatingTables() throws {
        let f = try Fixture()
        try f.transaction {
            let id = try f.id()
            for name in [
                "authority_review_applied", "authority_review_head", "authority_review_edge",
                "authority_review_event",
            ] {
                try f.index.execute("DROP TABLE " + name)
            }
            XCTAssertFalse(try f.index.authorityReviewApprovalCovers(revisionID: id, causes: []))
            XCTAssertFalse(try f.index.authorityReviewIsProvisional(revisionID: id))
            let statement = try f.index.corpusPrepare(
                "SELECT COUNT(*) FROM sqlite_master WHERE name='authority_review_event'")
            defer { sqlite3_finalize(statement) }
            XCTAssertEqual(f.index.catalogueStep(statement), SQLITE_ROW)
            XCTAssertEqual(sqlite3_column_int(statement, 0), 0)
        }
    }
    func testContextPreviewReturnsRealBFrontierWithoutAdmissionOrGrant() throws {
        let f = try Fixture()
        try f.transaction {
            let (a, initial) = try f.initial()
            let (p, b, _) = try f.plan(base: a, initial: initial)
            let before = try f.index.catalogueWatermark()
            let context = try f.index.previewAuthorityReviewContext(
                held: b.original, heldRow: b.row, loadVerified: f.load)
            XCTAssertEqual(context.analysis.frontier, [b.id])
            XCTAssertEqual(context.physicalHeads, [b.id])
            XCTAssertEqual(context.analysis.fields["isDeleted"], .boolean(true))
            XCTAssertEqual(try f.index.catalogueWatermark(), before)
            XCTAssertNil(try f.index.revision(b.id))
            XCTAssertEqual(try f.index.authorityDisposition(id: b.id)?.disposition, .held)
            XCTAssertFalse(
                try f.index.authorityReviewControlAllows(control: p.control.binding, revisionID: b.id))
            XCTAssertTrue(try f.index.acceptedGraphProofIsCurrent())
        }
    }
    func testPreviewRollsBackBothOriginalsDispositionsAndPrivateProof() throws {
        let f = try Fixture()
        try f.transaction {
            let (a, initial) = try f.initial()
            let (p, b, c) = try f.plan(base: a, initial: initial)
            let before = try f.index.catalogueWatermark()
            let projected = try f.index.previewAuthorityReview(
                plan: p, resolutionRow: c.row, loadVerified: f.load)
            XCTAssertEqual(projected.representative?.revisionID, c.id)
            XCTAssertEqual(try f.index.catalogueWatermark(), before)
            XCTAssertNil(try f.index.revision(b.id))
            XCTAssertNil(try f.index.revision(c.id))
            XCTAssertEqual(try f.index.authorityDisposition(id: b.id)?.disposition, .held)
            XCTAssertEqual(try f.index.authorityReviewDisposition(revisionID: b.id), .unknown)
            XCTAssertTrue(try f.index.acceptedGraphProofIsCurrent())
        }
    }
    func testAtomicApplyApprovesNamedBOnlyAndReplayIsQuiescent() throws {
        let f = try Fixture()
        try f.transaction {
            let (a, initial) = try f.initial()
            let (p, b, c) = try f.plan(base: a, initial: initial)
            let descendant = try f.item(parent: b, subject: "unreviewed descendant")
            let result = try f.index.applyValidatedReview(plan: p, resolutionRow: c.row, loadVerified: f.load)
            XCTAssertEqual(result.representative?.revisionID, c.id)
            XCTAssertEqual(result.analysis.fields["isDeleted"], .boolean(false))
            XCTAssertNotNil(try f.index.revision(b.id))
            XCTAssertNil(try f.index.revision(descendant.id))
            XCTAssertNotEqual(try f.index.authorityDisposition(id: descendant.id)?.disposition, .eligible)
            XCTAssertEqual(try f.index.authorityReviewDisposition(revisionID: b.id), .approved)
            XCTAssertTrue(
                try f.index.authorityReviewControlAllows(control: p.control.binding, revisionID: b.id))
            XCTAssertTrue(
                try f.index.authorityReviewControlAllows(control: p.control.binding, revisionID: c.id))
            XCTAssertFalse(
                try f.index.authorityReviewControlAllows(
                    control: p.control.binding, revisionID: descendant.id))
            XCTAssertFalse(
                try f.index.authorityReviewControlAllows(control: initial.binding, revisionID: b.id))
            XCTAssertTrue(
                try f.index.authorityReviewApprovalCovers(revisionID: b.id, causes: p.event.controlHolds))
            let before = try f.index.catalogueWatermark()
            _ = try f.index.applyValidatedReview(plan: p, resolutionRow: c.row, loadVerified: f.load)
            XCTAssertEqual(try f.index.catalogueWatermark(), before)
            XCTAssertFalse(
                try f.index.authorityLocallyExposed(revisionID: b.id),
                "Review application cannot fabricate visibility.")
        }
    }
    func testInvalidResolutionCannotExposeBOrChangeAcceptedProof() throws {
        let f = try Fixture()
        try f.transaction {
            let (a, initial) = try f.initial()
            let before = try f.index.catalogueWatermark()
            // The verified-plan boundary now rejects the incomplete explicit B choices
            // before the Index ever stages a review; keep the original no-grant checks.
            code("invalidAuthority") {
                _ = try f.plan(base: a, initial: initial, badPayload: true)
            }
            let candidates = try f.index.authorityPackagePage(packageID: f.package, limit: 128)
                .filter { $0.descriptor.kind == .item && $0.descriptor.id != a.id }
            XCTAssertEqual(candidates.count, 2)
            for row in candidates {
                XCTAssertNil(try f.index.revision(row.descriptor.id))
                XCTAssertNotEqual(
                    try f.index.authorityDisposition(id: row.descriptor.id)?.disposition, .eligible)
                XCTAssertEqual(
                    try f.index.authorityReviewDisposition(revisionID: row.descriptor.id), .unknown)
            }
            XCTAssertEqual(try f.index.catalogueWatermark(), before)
            XCTAssertEqual(try f.index.revisionCount(itemID: a.row.itemID), 1)
            XCTAssertTrue(try f.index.acceptedGraphProofIsCurrent())
        }
    }
    func testNewHoldSupersedesApprovalWithoutRestoringHistoricalGrant() throws {
        let f = try Fixture()
        try f.transaction {
            let (a, initial) = try f.initial()
            let (p, b, c) = try f.plan(base: a, initial: initial)
            _ = try f.index.applyValidatedReview(plan: p, resolutionRow: c.row, loadVerified: f.load)
            let hold = try f.hold(p, parents: [p.event.binding])
            try f.index.retainValidatedReviewHold(hold)
            XCTAssertEqual(try f.index.authorityReviewDisposition(revisionID: b.id), .held)
            XCTAssertFalse(
                try f.index.authorityReviewApprovalCovers(revisionID: b.id, causes: p.event.controlHolds))
            let before = try f.index.catalogueWatermark()
            code("operationReviewRequired") {
                _ = try f.index.applyValidatedReview(plan: p, resolutionRow: c.row, loadVerified: f.load)
            }
            XCTAssertEqual(try f.index.catalogueWatermark(), before)
            XCTAssertTrue(try f.index.acceptedGraphProofIsCurrent())
            XCTAssertEqual(
                try f.index.authorityReviewFrontier(revisionID: b.id).map(\.recordID), [hold.record.recordID])
            XCTAssertEqual(try f.index.authorityReviewDisposition(revisionID: b.id), .held)
        }
    }
    func testConcurrentHoldPreventsStaleReviewAndParentsAreBound() throws {
        let f = try Fixture()
        try f.transaction {
            let (a, initial) = try f.initial()
            let (p, b, c) = try f.plan(base: a, initial: initial)
            let hold = try f.hold(p, parents: [])
            try f.index.retainValidatedReviewHold(hold)
            code("revisionConflict") {
                _ = try f.index.applyValidatedReview(plan: p, resolutionRow: c.row, loadVerified: f.load)
            }
            XCTAssertNil(try f.index.revision(b.id))
            try f.index.retainValidatedReviewEvent(p.event)
            XCTAssertEqual(try f.index.authorityReviewFrontier(revisionID: b.id).count, 2)
            XCTAssertNotEqual(try f.index.authorityReviewDisposition(revisionID: b.id), .approved)
        }
    }
    func testCausalHoldCannotResurrectRemovedBOrCOnOldPlanRetry() throws {
        let f = try Fixture()
        try f.transaction {
            let (a, initial) = try f.initial()
            let (p, b, c) = try f.plan(base: a, initial: initial)
            _ = try f.index.applyValidatedReview(plan: p, resolutionRow: c.row, loadVerified: f.load)
            try f.index.retainValidatedControl(p.control)
            let h2 = try f.control(
                parents: [p.control.binding],
                effects: [
                    .init(target: b.target, eligible: false, actor: "fixture", policyIDs: []),
                    .init(target: c.target, eligible: false, actor: "fixture", policyIDs: []),
                ])
            try f.index.retainValidatedControl(h2)
            // The causal guard refuses even before the separate derived demotion catches up.
            code("operationReviewRequired") {
                _ = try f.index.applyValidatedReview(plan: p, resolutionRow: c.row, loadVerified: f.load)
            }
            for id in [b.id, c.id] {
                try f.index.setAuthorityDisposition(
                    id: id, evaluation: .init(disposition: .held, reason: "new validated H2"))
            }
            try f.index.reconcileAuthorityAcceptedItem(itemID: a.row.itemID)
            XCTAssertEqual(
                try f.index.authorityReviewDisposition(revisionID: b.id), .approved,
                "No canonical reviewHold was added: the newer cause is a control disposition.")
            let before = try f.index.catalogueWatermark()
            code("operationReviewRequired") {
                _ = try f.index.applyValidatedReview(plan: p, resolutionRow: c.row, loadVerified: f.load)
            }
            XCTAssertEqual(try f.index.catalogueWatermark(), before)
            XCTAssertNil(try f.index.revision(b.id))
            XCTAssertNil(try f.index.revision(c.id))
            XCTAssertEqual(try f.index.authorityDisposition(id: b.id)?.disposition, .held)
            XCTAssertEqual(try f.index.authorityDisposition(id: c.id)?.disposition, .held)
            XCTAssertTrue(try f.index.acceptedGraphProofIsCurrent())
            let current = try f.index.analyzeRevisionProjection(itemID: a.row.itemID, loadVerified: f.load)
            XCTAssertEqual(current.representative?.revisionID, a.id)
        }
    }
    func testAppliedPlanRetryKeepsLaterOrdinaryDescendantCurrent() throws {
        let f = try Fixture()
        try f.transaction {
            let (a, initial) = try f.initial()
            let (p, _, c) = try f.plan(base: a, initial: initial)
            _ = try f.index.applyValidatedReview(plan: p, resolutionRow: c.row, loadVerified: f.load)
            try f.index.retainValidatedControl(p.control)
            let e = try f.item(parent: c, subject: "later authored child", addressed: ["subject"])
            try f.index.setAuthorityDisposition(
                id: e.id, evaluation: .init(disposition: .eligible, reason: "fresh child fixture"))
            try f.index.appendValidatedPeer(row: e.row, revision: e.original, parent: c.original)
            let before = try f.index.catalogueWatermark()
            let current = try f.index.applyValidatedReview(
                plan: p, resolutionRow: c.row, loadVerified: f.load)
            XCTAssertEqual(current.representative?.revisionID, e.id)
            XCTAssertEqual(current.analysis.fields["subject"], .text("later authored child"))
            XCTAssertEqual(try f.index.catalogueWatermark(), before)
            XCTAssertTrue(try f.index.acceptedGraphProofIsCurrent())
        }
    }
    func testPreviewValidationRunsInsideStageAndFailureRestoresBothRows() throws {
        let f = try Fixture()
        try f.transaction {
            let (a, initial) = try f.initial()
            let (p, b, c) = try f.plan(base: a, initial: initial)
            code("invariantFixture") {
                _ = try f.index.previewAuthorityReview(
                    plan: p, resolutionRow: c.row, loadVerified: f.load,
                    validate: { snapshot in
                        XCTAssertNotNil(try f.index.revision(b.id))
                        XCTAssertNotNil(try f.index.revision(c.id))
                        XCTAssertEqual(snapshot.representative?.revisionID, c.id)
                        XCTAssertEqual(
                            try f.index.authorityDisposition(id: b.id)?.disposition, .held,
                            "Staging never installs B's grant before the final validated unit.")
                        throw TractandaError("invariantFixture", "reject staged references")
                    })
            }
            XCTAssertNil(try f.index.revision(b.id))
            XCTAssertNil(try f.index.revision(c.id))
            XCTAssertTrue(try f.index.acceptedGraphProofIsCurrent())
        }
    }
    func testReviewedRevocationKeepsEveryPREPolicyEdgeThroughTinyPagesAndRegrant() throws {
        let f = try Fixture()
        try f.transaction {
            func permission(_ mode: Int) -> ItemValue {
                .object([
                    "profile": .text(ItemPermissions.profile), "owner": .text("fixture"),
                    "group": .text("staff"), "mode": .integer(Int64(mode)), "acl": .object([:]),
                ])
            }
            let (a, initial) = try f.initial(permissions: permission(0o660))
            let left = try f.item(parent: a, subject: "left", addressed: ["subject"])
            let right = try f.item(parent: a, subject: "right", addressed: ["subject"])
            for branch in [left, right] {
                try f.index.setAuthorityDisposition(
                    id: branch.id, evaluation: .init(disposition: .eligible, reason: "verified PRE fixture"))
                try f.index.appendValidatedPeer(
                    row: branch.row, revision: branch.original, parent: a.original)
            }
            let accepted = try f.control(
                parents: [initial.binding],
                effects: [
                    .init(target: left.target, eligible: true, actor: "fixture", policyIDs: []),
                    .init(target: right.target, eligible: true, actor: "fixture", policyIDs: []),
                ])
            try f.index.retainValidatedControl(accepted)
            let (p, _, c) = try f.plan(
                base: left, initial: accepted, policies: [left, right], otherParents: [right],
                resolutionChanges: ["permissions": permission(0o600)])
            _ = try f.index.applyValidatedReview(plan: p, resolutionRow: c.row, loadVerified: f.load)
            // Exact review application alone cannot stand in for validated post-control admission.
            code("invalidAuthorityReview") {
                try f.index.retainValidatedReviewInvalidation(p, previous: left.original)
            }
            try f.index.retainValidatedControl(p.control)
            for previous in [left, right, left] {
                try f.index.retainValidatedReviewInvalidation(p, previous: previous.original)
            }
            code("invalidAuthorityReview") {
                try f.index.retainValidatedReviewInvalidation(p, previous: a.original)
            }
            var cursor: (controlID: String, previousPolicyID: String)?
            var rows: [AuthorityStore.Invalidation] = []
            var ended = false
            for _ in 0..<3 {
                let page = try f.index.authorityInvalidationPage(
                    policyItemID: a.row.itemID, after: cursor, limit: 1)
                if page.isEmpty {
                    ended = true
                    break
                }
                XCTAssertEqual(page.count, 1)
                rows += page
                cursor = (page[0].control.recordID, page[0].previousPolicyID)
            }
            XCTAssertTrue(ended)
            XCTAssertEqual(Set(rows.map(\.previousPolicyID)), Set([left.id, right.id]))
            XCTAssertTrue(rows.allSatisfy { $0.control == p.control.binding && $0.policy == c.target })
            let grant = try f.item(
                parent: c, subject: "later grant", addressed: ["permissions", "subject"],
                changes: ["permissions": permission(0o660)])
            try f.index.setAuthorityDisposition(
                id: grant.id,
                evaluation: .init(disposition: .eligible, reason: "verified local grant fixture"))
            // This represents an already-authorized local protected write; foreign ordinary
            // append deliberately remains barred from changing permissions.
            try f.index.insertRecoveryRow(grant.row, graphFields: grant.original.revision.fields)
            try f.index.validateRecoveryGraph(requireLinearProjection: false)
            let g = try f.control(
                parents: [p.control.binding],
                effects: [.init(target: grant.target, eligible: true, actor: "fixture", policyIDs: [c.id])])
            try f.index.retainValidatedControl(g)
            try f.index.retainValidatedInvalidation(
                .init(
                    control: g.binding, sourceCut: p.control.binding, policy: grant.original,
                    previousPolicyID: c.id))
            let all = try f.index.authorityInvalidationPage(policyItemID: a.row.itemID)
            XCTAssertEqual(all.count, 3)
            XCTAssertEqual(
                all.filter { $0.control == p.control.binding }.count, 2,
                "G must not erase C's intermediate revocation.")
            XCTAssertEqual(all.filter { $0.control == g.binding }.map(\.previousPolicyID), [c.id])
            let query = try f.index.corpusPrepare(
                "EXPLAIN QUERY PLAN SELECT control,sha256,cut,cut_digest,item,revision,digest,previous FROM authority_invalidation WHERE item=? AND (control,previous)>(?,?) ORDER BY control,previous LIMIT 1",
                [a.row.itemID, p.control.binding.recordID, left.id])
            defer { sqlite3_finalize(query) }
            var planText = ""
            while f.index.catalogueStep(query) == SQLITE_ROW {
                if let detail = sqlite3_column_text(query, 3) { planText += String(cString: detail) }
            }
            XCTAssertTrue(planText.contains("authority_invalidation_item"))
            XCTAssertFalse(planText.uppercased().contains("TEMP B-TREE"))
        }
    }
    func testReviewInvalidationRefusesProvisionalAndUnsupportedPolicyProof() throws {
        let f = try Fixture()
        try f.transaction {
            let (a, initial) = try f.initial()
            let (p, _, c) = try f.plan(base: a, initial: initial)
            try f.index.retainRecoveryAuthorityReview(plan: p)
            // Even a normalized positive post-control cannot turn a provisional
            // review marker into a fully validated policy transition.
            try f.index.retainValidatedControl(p.control)
            code("invalidAuthorityReview") {
                try f.index.retainValidatedReviewInvalidation(p, previous: a.original)
            }
            // A distinct fresh fixture reaches full application but changes lifecycle only.
            // Such a review is not permission/admission revocation evidence.
            let other = try Fixture()
            try other.transaction {
                let (root, cut) = try other.initial()
                let (review, _, result) = try other.plan(base: root, initial: cut)
                _ = try other.index.applyValidatedReview(
                    plan: review, resolutionRow: result.row, loadVerified: other.load)
                try other.index.retainValidatedControl(review.control)
                code("invalidAuthority") {
                    try AuthorityStore.validateReviewPolicyTransition(review, previous: root.original)
                }
                code("invalidAuthority") {
                    try other.index.retainValidatedReviewInvalidation(review, previous: root.original)
                }
                XCTAssertTrue(
                    try other.index.authorityInvalidationPage(policyItemID: root.row.itemID).isEmpty)
            }
            XCTAssertFalse(try f.index.authorityReviewRecoveryIsComplete())
            XCTAssertNil(try f.index.revision(c.id))
        }
    }
    func testExistingConcreteSubclassAndRetypeSharePreflightAndRegistration() throws {
        func permission(_ mode: Int) -> ItemValue {
            .object([
                "profile": .text(ItemPermissions.profile), "owner": .text("fixture"),
                "group": .text("staff"), "mode": .integer(Int64(mode)), "acl": .object([:]),
            ])
        }
        for resultClass in ["DeadlineItem", "AppointmentItem"] {
            let f = try Fixture()
            try f.transaction {
                let (a, initial) = try f.initial(permissions: permission(0o660), classID: "DeadlineItem")
                let (p, _, c) = try f.plan(
                    base: a, initial: initial,
                    resolutionChanges: ["permissions": permission(0o600), "classID": .text(resultClass)])
                // Store uses this identical pure shape check BEFORE any seal/publication.
                XCTAssertNoThrow(try AuthorityStore.validateReviewPolicyTransition(p, previous: a.original))
                _ = try f.index.applyValidatedReview(plan: p, resolutionRow: c.row, loadVerified: f.load)
                try f.index.retainValidatedControl(p.control)
                try f.index.retainValidatedReviewInvalidation(p, previous: a.original)
                let transitions = try f.index.authorityInvalidationPage(policyItemID: a.row.itemID)
                XCTAssertEqual(transitions.count, 1)
                XCTAssertEqual(transitions.first?.previousPolicyID, a.id)
                XCTAssertEqual(transitions.first?.policy, c.target)
                XCTAssertEqual(c.original.revision.classID, resultClass)
            }
        }
    }
    func testAccessConfigurationRetypeAndAbstractClassRefuseBeforeSeal() throws {
        let f = try Fixture()
        try f.transaction {
            let (a, initial) = try f.initial()
            let configuration: ItemValue = .object([
                "profile": .text(AccessConfiguration.profile), "users": .list([.text("fixture")]),
                "administration": .text("system"),
            ])
            let (p, b, c) = try f.plan(
                base: a, initial: initial,
                resolutionChanges: [
                    "classID": .text(AccessConfiguration.classID), "accessConfiguration": configuration,
                ])
            code("invalidAuthority") {
                try AuthorityStore.validateReviewPolicyTransition(p, previous: a.original)
            }
            XCTAssertNil(try f.index.revision(b.id))
            XCTAssertNil(try f.index.revision(c.id))
            XCTAssertEqual(try f.index.authorityDisposition(id: b.id)?.disposition, .held)
            XCTAssertTrue(try f.index.authorityInvalidationPage(policyItemID: a.row.itemID).isEmpty)
            code("abstractClass") {
                _ = try f.item(parent: a, changes: ["classID": .text("PersonItem")])
            }
            XCTAssertEqual(try f.index.revisionCount(itemID: a.row.itemID), 1)
            XCTAssertTrue(try f.index.acceptedGraphProofIsCurrent())
        }
    }
    func testAppliedReviewConsumesOnlyCoveredPendingBAndCWithoutChangingEligibility() throws {
        let f = try Fixture()
        try f.transaction {
            let (a, initial) = try f.initial()
            let (p, b, c) = try f.plan(base: a, initial: initial)
            _ = try f.index.applyValidatedReview(plan: p, resolutionRow: c.row, loadVerified: f.load)
            try f.index.retainValidatedControl(p.control)
            try f.index.retainLocalAuthorityAcceptance(p.control)
            let before = try f.index.catalogueWatermark()
            for target in [b.target, c.target] {
                try f.index.noteAuthorityDispositionEffect(
                    .init(
                        target: target, eligible: false, actor: "fixture", policyIDs: [a.id],
                        causes: p.event.controlHolds))
                try f.index.consumeSupersededAuthorityEffect(
                    control: p.control.binding, originID: f.origin, target: target, cut: p.event.preCut,
                    review: p)
                try f.index.consumeSupersededAuthorityEffect(
                    control: p.control.binding, originID: f.origin, target: target, cut: p.event.preCut,
                    review: p)
                XCTAssertEqual(
                    try f.index.authorityDisposition(id: target.revisionID)?.disposition, .eligible)
                XCTAssertFalse(try f.index.authorityLocallyExposed(revisionID: target.revisionID))
            }
            XCTAssertTrue(try f.index.authorityDispositionEffectPage().isEmpty)
            XCTAssertEqual(try f.index.catalogueWatermark(), before)
            XCTAssertEqual(try f.index.authorityControlHead(originID: f.origin), p.control.binding)
            let remote = try f.record(
                .controlCommit,
                payload: [
                    "controls": .list([p.control.binding.itemValue]), "localParent": .list([]),
                    "bootstrap": .list([]),
                    "deltas": .list([
                        AuthorityStore.DispositionDelta(
                            target: b.target, eligible: false, actor: "fixture", policyIDs: []
                        ).itemValue
                    ]),
                ], parents: [p.control.binding], issuer: f.id())
            let newer = try AuthorityStore.VerifiedControlPlan(control: remote)
            try f.index.retainValidatedControl(newer)
            try f.index.noteAuthorityDispositionEffect(
                .init(
                    target: b.target, eligible: false, actor: "fixture", policyIDs: [],
                    causes: [newer.binding]))
            try f.index.consumeSupersededAuthorityEffect(
                control: p.control.binding, originID: f.origin, target: b.target, cut: p.event.preCut,
                review: p)
            XCTAssertEqual(
                try f.index.authorityDispositionEffectPage().first?.causes, [newer.binding],
                "Newer uncovered H2 survives an older D cleanup.")
        }
    }
    func testIndependentAuthoredEffectNeedsSelectedEvidenceAndActualCoveredSourceCut() throws {
        let f = try Fixture()
        try f.transaction {
            let (a, initial) = try f.initial()
            let (p, _, c) = try f.plan(base: a, initial: initial)
            _ = try f.index.applyValidatedReview(plan: p, resolutionRow: c.row, loadVerified: f.load)
            try f.index.retainValidatedControl(p.control)
            let g = try f.item(parent: c, subject: "independently authorized G", addressed: ["subject"])
            let evidence = try f.evidence(g, cut: p.control.binding)
            let binding = try AuthorityBinding(recordID: evidence.record.recordID, sha256: evidence.sha256)
            try f.index.setAuthorityDisposition(
                id: g.id, evaluation: .init(disposition: .eligible, reason: "fixture"))
            try f.index.appendValidatedPeer(row: g.row, revision: g.original, parent: c.original)
            let accepted = try f.control(
                parents: [p.control.binding],
                effects: [
                    .init(
                        target: g.target, eligible: true, actor: "fixture", policyIDs: [c.id],
                        evidence: binding)
                ])
            try f.index.retainValidatedControl(accepted)
            try f.index.retainLocalAuthorityAcceptance(accepted)
            try f.index.noteAuthorityDispositionEffect(
                .init(
                    target: g.target, eligible: false, actor: "fixture", policyIDs: [a.id],
                    causes: p.event.controlHolds))
            code("invalidAuthorityReview") {
                try f.index.consumeSupersededAuthorityEffect(
                    control: accepted.binding, originID: f.origin, target: g.target, cut: p.control.binding,
                    original: g.original, evidence: evidence)
            }
            XCTAssertEqual(
                try f.index.authorityDispositionEffectPage().count, 1,
                "Raw retained testimony is insufficient.")
            try f.index.setAuthorityDisposition(
                id: g.id,
                evaluation: .init(
                    disposition: .eligible, reason: "selected exact accepted proof",
                    evidenceID: binding.recordID, evidenceDigest: binding.sha256, evidencePackageID: f.package
                ))
            try f.index.consumeSupersededAuthorityEffect(
                control: accepted.binding, originID: f.origin, target: g.target, cut: p.control.binding,
                original: g.original, evidence: evidence)
            try f.index.consumeSupersededAuthorityEffect(
                control: accepted.binding, originID: f.origin, target: g.target, cut: p.control.binding,
                original: g.original, evidence: evidence)
            XCTAssertTrue(try f.index.authorityDispositionEffectPage().isEmpty)
            XCTAssertEqual(try f.index.authorityDisposition(id: g.id)?.disposition, .eligible)
            XCTAssertFalse(try f.index.authorityLocallyExposed(revisionID: g.id))
        }
    }
    func testOfflineXCannotConsumeRevocationThroughClaimedNewerCut() throws {
        let f = try Fixture()
        try f.transaction {
            let (a, initial) = try f.initial()
            let x = try f.item(parent: a, subject: "before R offline X", addressed: ["subject"])
            let evidence = try f.evidence(x, cut: initial.binding)
            let eb = try AuthorityBinding(recordID: evidence.record.recordID, sha256: evidence.sha256)
            try f.index.setAuthorityDisposition(
                id: x.id,
                evaluation: .init(
                    disposition: .eligible, reason: "historically selected", evidenceID: eb.recordID,
                    evidenceDigest: eb.sha256, evidencePackageID: f.package))
            try f.index.appendValidatedPeer(row: x.row, revision: x.original, parent: a.original)
            let accepted = try f.control(
                parents: [initial.binding],
                effects: [
                    .init(target: x.target, eligible: true, actor: "fixture", policyIDs: [a.id], evidence: eb)
                ])
            try f.index.retainValidatedControl(accepted)
            try f.index.retainLocalAuthorityAcceptance(accepted)
            let remote = try f.record(
                .controlCommit,
                payload: [
                    "controls": .list([initial.binding.itemValue]), "localParent": .list([]),
                    "bootstrap": .list([]),
                    "deltas": .list([
                        AuthorityStore.DispositionDelta(
                            target: x.target, eligible: false, actor: "fixture", policyIDs: [a.id]
                        ).itemValue
                    ]),
                ], parents: [initial.binding], issuer: f.id())
            let revocation = try AuthorityStore.VerifiedControlPlan(control: remote)
            try f.index.retainValidatedControl(revocation)
            try f.index.noteAuthorityDispositionEffect(
                .init(
                    target: x.target, eligible: false, actor: "fixture", policyIDs: [a.id],
                    causes: [revocation.binding]))
            try f.index.consumeSupersededAuthorityEffect(
                control: accepted.binding, originID: f.origin, target: x.target, cut: initial.binding,
                original: x.original, evidence: evidence)
            XCTAssertEqual(try f.index.authorityDispositionEffectPage().first?.target, x.target)
            code("invalidAuthorityReview") {
                try f.index.consumeSupersededAuthorityEffect(
                    control: accepted.binding, originID: f.origin, target: x.target, cut: revocation.binding,
                    original: x.original, evidence: evidence)
            }
            XCTAssertEqual(try f.index.authorityDispositionEffectPage().first?.causes, [revocation.binding])
        }
    }
    func testPendingConsumptionRejectsWrongHeadFingerprintAndProvisionalReview() throws {
        let f = try Fixture()
        try f.transaction {
            let (a, initial) = try f.initial()
            let (p, b, c) = try f.plan(base: a, initial: initial)
            try f.index.retainRecoveryAuthorityReview(plan: p)
            try f.index.retainValidatedControl(p.control)
            try f.index.retainLocalAuthorityAcceptance(p.control)
            let pending = AuthorityStore.DispositionDelta(
                target: b.target, eligible: false, actor: "fixture", policyIDs: [],
                causes: p.event.controlHolds)
            try f.index.noteAuthorityDispositionEffect(pending)
            code("invalidAuthorityReview") {
                try f.index.consumeSupersededAuthorityEffect(
                    control: p.control.binding, originID: f.origin, target: b.target, cut: p.event.preCut,
                    review: p)
            }
            XCTAssertEqual(try f.index.authorityDispositionEffectPage().count, 1)
            try f.index.insertRecoveryRow(c.row, graphFields: c.original.revision.fields)
            try f.index.insertRecoveryRow(b.row, graphFields: b.original.revision.fields)
            try f.index.validateRecoveryGraph(requireLinearProjection: false)
            _ = try f.index.analyzeRevisionProjection(itemID: a.row.itemID, loadVerified: f.load)
            try f.index.execute(
                "UPDATE authority_pending_effect SET fingerprint=? WHERE revision=?",
                [String(repeating: "0", count: 64), b.id])
            code("invalidAuthorityReview") {
                try f.index.consumeSupersededAuthorityEffect(
                    control: p.control.binding, originID: f.origin, target: b.target, cut: p.event.preCut,
                    review: p)
            }
            try f.index.noteAuthorityDispositionEffect(pending)
            let h2 = try f.control(
                parents: [p.control.binding],
                effects: [.init(target: b.target, eligible: false, actor: "fixture", policyIDs: [])])
            try f.index.retainValidatedControl(h2)
            code("invalidAuthorityReview") {
                try f.index.consumeSupersededAuthorityEffect(
                    control: p.control.binding, originID: f.origin, target: b.target, cut: p.event.preCut,
                    review: p)
            }
            XCTAssertEqual(try f.index.authorityDispositionEffectPage().count, 1)
            XCTAssertTrue(try f.index.acceptedGraphProofIsCurrent())
        }
    }
    func testRestoreLocallyAcceptedGIsIncrementalIdempotentAndPreservesSuccessor() throws {
        let f = try Fixture()
        try f.transaction {
            let (a, initial) = try f.initial()
            let (p, _, c) = try f.plan(base: a, initial: initial)
            _ = try f.index.applyValidatedReview(plan: p, resolutionRow: c.row, loadVerified: f.load)
            try f.index.retainValidatedControl(p.control)
            let (g, evidence, positive) = try f.locallyAcceptedAuthored(parent: c, source: p.control.binding)
            XCTAssertNil(try f.index.revision(g.id))
            let queue = try f.index.authorityLocalVisibilityWorkCount()
            var limits = RevisionProjection.Limits()
            limits.maximumVMInstructions = 1
            code("resourceLimit") {
                try f.index.restoreLocallyAcceptedAuthored(
                    row: g.row, original: g.original, control: positive.binding, evidence: evidence,
                    loadVerified: f.load, limits: limits)
            }
            code("restoreCancelled") {
                try f.index.restoreLocallyAcceptedAuthored(
                    row: g.row, original: g.original, control: positive.binding, evidence: evidence,
                    loadVerified: f.load, progress: { throw TractandaError("restoreCancelled", "fixture") })
            }
            XCTAssertNil(try f.index.revision(g.id))
            XCTAssertTrue(try f.index.acceptedGraphProofIsCurrent())
            try f.index.restoreLocallyAcceptedAuthored(
                row: g.row, original: g.original, control: positive.binding, evidence: evidence,
                loadVerified: f.load)
            XCTAssertEqual(try f.index.revision(g.id), g.row)
            let before = try f.index.catalogueWatermark()
            try f.index.restoreLocallyAcceptedAuthored(
                row: g.row, original: g.original, control: positive.binding, evidence: evidence,
                loadVerified: f.load)
            XCTAssertEqual(try f.index.catalogueWatermark(), before)
            XCTAssertEqual(try f.index.authorityLocalVisibilityWorkCount(), queue)
            XCTAssertFalse(try f.index.authorityLocallyExposed(revisionID: g.id))
            XCTAssertEqual(try f.index.authorityDisposition(id: g.id)?.disposition, .eligible)
            let snapshot = try f.index.analyzeRevisionProjection(itemID: g.row.itemID, loadVerified: f.load)
            XCTAssertEqual(snapshot.representative?.revisionID, g.id)
            let r = g.row
            let mismatch = ItemIndex.CatalogueRow(
                revisionID: r.revisionID, itemID: r.itemID, path: r.path, parentID: r.parentID,
                actor: r.actor, operationID: r.operationID, size: r.size, inode: r.inode, uid: r.uid,
                mode: r.mode, modificationSeconds: r.modificationSeconds,
                modificationNanoseconds: r.modificationNanoseconds, digest: Data(repeating: 0, count: 32),
                createdAt: r.createdAt, feedbackRevisionIDs: r.feedbackRevisionIDs, modifiedAt: r.modifiedAt,
                provenance: r.provenance)
            code("invalidAuthorityReview") {
                try f.index.restoreLocallyAcceptedAuthored(
                    row: mismatch, original: g.original, control: positive.binding, evidence: evidence,
                    loadVerified: f.load)
            }
            XCTAssertEqual(try f.index.catalogueWatermark(), before)
            XCTAssertTrue(try f.index.acceptedGraphProofIsCurrent())
        }
    }
    func testRestoreRefusesRawNonlocalWrongControlAndHeldProof() throws {
        let f = try Fixture()
        try f.transaction {
            let (a, initial) = try f.initial()
            let (p, _, c) = try f.plan(base: a, initial: initial)
            _ = try f.index.applyValidatedReview(plan: p, resolutionRow: c.row, loadVerified: f.load)
            try f.index.retainValidatedControl(p.control)
            let (g, evidence, positive) = try f.locallyAcceptedAuthored(
                parent: c, source: p.control.binding, selected: false)
            code("invalidAuthorityReview") {
                try f.index.restoreLocallyAcceptedAuthored(
                    row: g.row, original: g.original, control: positive.binding, evidence: evidence,
                    loadVerified: f.load)
            }
            let eb = try AuthorityBinding(recordID: evidence.record.recordID, sha256: evidence.sha256)
            try f.index.setAuthorityDisposition(
                id: g.id,
                evaluation: .init(
                    disposition: .eligible, reason: "selected", evidenceID: eb.recordID,
                    evidenceDigest: eb.sha256, evidencePackageID: f.package))
            try f.index.execute(
                "DELETE FROM authority_local_acceptance WHERE control=?", [positive.binding.recordID])
            code("invalidAuthorityReview") {
                try f.index.restoreLocallyAcceptedAuthored(
                    row: g.row, original: g.original, control: positive.binding, evidence: evidence,
                    loadVerified: f.load)
            }
            try f.index.retainLocalAuthorityAcceptance(positive)
            code("invalidAuthorityReview") {
                try f.index.restoreLocallyAcceptedAuthored(
                    row: g.row, original: g.original, control: p.control.binding, evidence: evidence,
                    loadVerified: f.load)
            }
            try f.index.setAuthorityDisposition(
                id: g.id, evaluation: .init(disposition: .held, reason: "new denied fact"))
            code("invalidAuthorityReview") {
                try f.index.restoreLocallyAcceptedAuthored(
                    row: g.row, original: g.original, control: positive.binding, evidence: evidence,
                    loadVerified: f.load)
            }
            XCTAssertNil(try f.index.revision(g.id))
            XCTAssertTrue(try f.index.acceptedGraphProofIsCurrent())
        }
    }
    func testRestoreMissingParentAndProvisionalParentRemainGated() throws {
        let f = try Fixture()
        try f.transaction {
            let (a, initial) = try f.initial()
            let (p, _, c) = try f.plan(base: a, initial: initial)
            _ = try f.index.applyValidatedReview(plan: p, resolutionRow: c.row, loadVerified: f.load)
            try f.index.retainValidatedControl(p.control)
            let (missing, _, intermediate) = try f.locallyAcceptedAuthored(
                parent: c, source: p.control.binding)
            let (g, evidence, positive) = try f.locallyAcceptedAuthored(
                parent: missing, source: intermediate.binding)
            code("missingDependencies") {
                try f.index.restoreLocallyAcceptedAuthored(
                    row: g.row, original: g.original, control: positive.binding, evidence: evidence,
                    loadVerified: f.load)
            }
            XCTAssertNil(try f.index.revision(g.id))
            XCTAssertNil(try f.index.revision(missing.id))
            XCTAssertTrue(try f.index.acceptedGraphProofIsCurrent())
        }
        let provisional = try Fixture()
        try provisional.transaction {
            let (a, initial) = try provisional.initial()
            let (p, b, c) = try provisional.plan(base: a, initial: initial)
            try provisional.index.retainRecoveryAuthorityReview(plan: p)
            try provisional.index.retainValidatedControl(p.control)
            try provisional.index.insertRecoveryRow(c.row, graphFields: c.original.revision.fields)
            try provisional.index.insertRecoveryRow(b.row, graphFields: b.original.revision.fields)
            try provisional.index.validateRecoveryGraph(requireLinearProjection: false)
            let (g, evidence, positive) = try provisional.locallyAcceptedAuthored(
                parent: c, source: p.control.binding)
            code("invalidAuthorityReview") {
                try provisional.index.restoreLocallyAcceptedAuthored(
                    row: g.row, original: g.original, control: positive.binding, evidence: evidence,
                    loadVerified: provisional.load)
            }
            XCTAssertTrue(try provisional.index.authorityReviewIsProvisional(revisionID: c.id))
            XCTAssertNil(try provisional.index.revision(g.id))
            XCTAssertTrue(try provisional.index.acceptedGraphProofIsCurrent())
        }
    }
    func testRestoreRejectsActualAuthoredDeltaAndUnsafeParentClock() throws {
        for malformed in ["delta", "clock"] {
            let f = try Fixture()
            try f.transaction {
                let (a, initial) = try f.initial()
                let (p, _, c) = try f.plan(base: a, initial: initial)
                _ = try f.index.applyValidatedReview(plan: p, resolutionRow: c.row, loadVerified: f.load)
                try f.index.retainValidatedControl(p.control)
                let (g, evidence, positive) = try f.locallyAcceptedAuthored(
                    parent: c, source: p.control.binding,
                    addressed: malformed == "delta" ? ["isDeleted"] : ["subject"],
                    changes: malformed == "clock"
                        ? ["modifiedAt": .date(c.original.revision.modifiedAt)] : [:])
                let before = try f.index.catalogueWatermark()
                code("invalidAuthorityReview") {
                    try f.index.restoreLocallyAcceptedAuthored(
                        row: g.row, original: g.original, control: positive.binding, evidence: evidence,
                        loadVerified: f.load)
                }
                XCTAssertNil(try f.index.revision(g.id))
                XCTAssertEqual(try f.index.catalogueWatermark(), before)
                XCTAssertTrue(try f.index.acceptedGraphProofIsCurrent())
            }
        }
    }
    func testRecoveryIsProvisionalUntilFullOwnContextValidation() throws {
        let f = try Fixture()
        try f.transaction {
            let (a, initial) = try f.initial()
            let (p, b, c) = try f.plan(base: a, initial: initial)
            XCTAssertFalse(try f.index.authorityReviewIsProvisional(revisionID: b.id))
            try f.index.retainRecoveryAuthorityReview(plan: p)
            XCTAssertEqual(try f.index.authorityReviewItemPage(limit: 1), [a.row.itemID])
            XCTAssertTrue(try f.index.authorityReviewItemPage(after: a.row.itemID, limit: 1).isEmpty)
            XCTAssertTrue(try f.index.authorityReviewIsProvisional(revisionID: b.id))
            XCTAssertTrue(try f.index.authorityReviewIsProvisional(revisionID: c.id))
            XCTAssertFalse(try f.index.authorityReviewIsProvisional(revisionID: a.id))
            XCTAssertFalse(try f.index.authorityRecoveryProjectionIsComplete())
            XCTAssertNotEqual(try f.index.authorityReviewDisposition(revisionID: b.id), .approved)
            // Opposite physical order is legal: complete graph admission supplies order.
            try f.index.insertRecoveryRow(c.row, graphFields: c.original.revision.fields)
            try f.index.insertRecoveryRow(b.row, graphFields: b.original.revision.fields)
            try f.index.validateRecoveryGraph(requireLinearProjection: false)
            let projected = try f.index.analyzeRevisionProjection(itemID: a.row.itemID, loadVerified: f.load)
            XCTAssertEqual(projected.representative?.revisionID, c.id)
            XCTAssertTrue(try f.index.authorityRecoveryProjectionIsComplete())
            XCTAssertFalse(try f.index.authorityReviewIsProvisional(revisionID: b.id))
            XCTAssertFalse(try f.index.authorityReviewIsProvisional(revisionID: c.id))
            XCTAssertEqual(try f.index.authorityReviewDisposition(revisionID: b.id), .approved)
            try f.index.clearAuthorityReviewDerivedState()
            XCTAssertEqual(try f.index.authorityReviewDisposition(revisionID: b.id), .unknown)
        }
    }
    func testCancellationAndWorkLimitsRestoreSavepointAndProof() throws {
        let f = try Fixture()
        try f.transaction {
            let (a, initial) = try f.initial()
            let (p, b, c) = try f.plan(base: a, initial: initial)
            code("reviewCancelled") {
                _ = try f.index.previewAuthorityReview(
                    plan: p, resolutionRow: c.row, loadVerified: f.load,
                    progress: { throw TractandaError("reviewCancelled", "fixture") })
            }
            XCTAssertTrue(try f.index.acceptedGraphProofIsCurrent())
            var limits = RevisionProjection.Limits()
            limits.maximumVMInstructions = 1
            code("resourceLimit") {
                _ = try f.index.previewAuthorityReview(
                    plan: p, resolutionRow: c.row, loadVerified: f.load, limits: limits)
            }
            limits = .init()
            limits.maximumHydratedBytes = 1
            code("resourceLimit") {
                _ = try f.index.previewAuthorityReview(
                    plan: p, resolutionRow: c.row, loadVerified: f.load, limits: limits)
            }
            XCTAssertNil(try f.index.revision(b.id))
            XCTAssertNil(try f.index.revision(c.id))
            XCTAssertTrue(try f.index.acceptedGraphProofIsCurrent())
            let holds = try f.index.authorityReviewControlHolds(revisionID: b.id, cut: p.event.preCut)
            XCTAssertEqual(holds, p.event.controlHolds)
        }
    }
}
