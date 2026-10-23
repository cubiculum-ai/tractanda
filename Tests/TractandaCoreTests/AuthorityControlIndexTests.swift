import CSQLite
import Crypto
import XCTest

@testable import TractandaCore

final class AuthorityControlIndexTests: XCTestCase {
    func testSourcePolicyFrontierRequiresCutIssuerAdmissionAndCompleteEligibility() throws {
        let f = try Fixture()
        let a = try f.item(subject: "local policy")
        let b = try f.item(subject: "foreign opinion")
        let remote = try f.id()
        let prior = try f.commit(changes: [(a, true)], origin: f.origin)
        let foreign = try f.commit(changes: [(b, true)], origin: remote)
        let joined = try f.commit(
            parents: [prior.binding, foreign.binding], origin: f.origin,
            localParent: prior.binding)
        XCTAssertEqual(try f.index.eligibilityAtCut(revisionID: b.id, cut: joined.binding), .eligible)
        XCTAssertTrue(
            try f.index.authorityItemFrontierAtCut(itemID: b.target.itemID, cut: joined.binding).isEmpty)
        let admitted = try f.commit(
            parents: [joined.binding], changes: [(b, true)], origin: f.origin,
            localParent: joined.binding)
        XCTAssertEqual(
            try f.index.authorityItemFrontierAtCut(itemID: b.target.itemID, cut: admitted.binding), [b.id])
        XCTAssertTrue(
            try f.index.authorityItemFrontierAtCut(itemID: b.target.itemID, cut: joined.binding).isEmpty,
            "A later local admission cannot supply an older exact source cut.")
        let held = try f.commit(
            parents: [admitted.binding, foreign.binding], changes: [(b, false)],
            origin: remote, localParent: foreign.binding)
        let complete = try f.commit(
            parents: [admitted.binding, held.binding], origin: f.origin,
            localParent: admitted.binding)
        XCTAssertEqual(try f.index.eligibilityAtCut(revisionID: b.id, cut: complete.binding), .held)
        XCTAssertTrue(
            try f.index.authorityItemFrontierAtCut(itemID: b.target.itemID, cut: complete.binding).isEmpty,
            "Earlier positive admission cannot bypass a genuine complete-cut hold.")
    }
    func testAcceptedSupportCursorPreservesLegacyFactsAndBoundedParents() throws {
        let f = try Fixture()
        let a = try f.item()
        let b = try f.item()
        let prior = try f.commit(changes: [(a, true)], origin: f.origin)
        let plan = try f.commit(
            parents: [prior.binding], changes: [(a, false), (b, true)], origin: f.origin,
            localParent: prior.binding)
        var cursor: AuthorityStore.SupportCursor?
        var facts: [ItemValue] = []
        while let next = try f.index.acceptedControlSupports(plan.binding, after: cursor, limit: 1).first {
            facts.append(next.delta.itemValue)
            XCTAssertEqual(
                next.fingerprint, AuthorityRecordCodec.sha256(try JSON.encode(next.delta.itemValue)))
            cursor = next.cursor
        }
        XCTAssertEqual(facts, plan.deltas.map(\.itemValue))
        XCTAssertEqual(try f.index.acceptedControlParents(plan.binding, limit: 1), [prior.binding])
        XCTAssertTrue(
            try f.index.acceptedControlParents(plan.binding, afterRecordID: prior.binding.recordID).isEmpty)
    }

    func testAtomicOriginalPREWindowsReduceAllParentsAndCoveredAncestors() throws {
        let f = try Fixture()
        let a = try f.item()
        let old = try f.commit(changes: [(a, false)])
        // This Index fixture supplies already accepted facts; it does not claim ordinary positive
        // authorization after a hold. Actual producer/D/B/C/receiver proof is a Store-level case.
        let later = try f.commit(parents: [old.binding], changes: [(a, true)])
        let concurrent = try f.commit(changes: [(a, false)])
        for (parents, expected) in [
            ([old.binding, later.binding], AuthorityStore.HistoricalEligibility.eligible),
            ([later.binding, concurrent.binding], .held),
        ] {
            let draft = try f.commit(parents: parents, admit: false)
            let walk = try AtomicAuthorityOriginalPRE(
                index: f.index, source: .legacy(draft), target: a.target)
            defer { try? walk.close() }
            var result: AuthorityStore.HistoricalEligibility?
            for _ in 0..<128 where result == nil { result = try walk.step(maximumUnits: 1) }
            XCTAssertEqual(result, expected)
            XCTAssertGreaterThan(walk.processedUnits, 2)
            try walk.close()
        }
        XCTAssertEqual(try f.count("authority_control_work"), 0)
    }

    func testGloballyAbsentOriginalPREAvoidsHistoryWalkWithoutInventingMembership() throws {
        let f = try Fixture()
        let known = try f.item()
        let absent = try f.item()
        let first = try f.commit(changes: [(known, false)])
        var head = first
        for _ in 0..<8 { head = try f.commit(parents: [head.binding]) }
        let unrelated = try f.commit()
        let draft = try f.commit(parents: [head.binding], admit: false)
        let work = try AtomicAuthorityOriginalPRE(
            index: f.index, source: .legacy(draft), target: absent.target)
        defer { try? work.close() }
        XCTAssertEqual(try work.step(maximumUnits: 1), .unknown)
        XCTAssertEqual(work.processedUnits, 0)
        XCTAssertTrue(try work.contains(head.binding))
        XCTAssertTrue(
            try work.contains(first.binding),
            "An ancestor denial/context cause is not erased for a new target")
        XCTAssertEqual(try f.index.eligibilityAtCut(revisionID: known.id, cut: head.binding), .held)
        XCTAssertFalse(try work.contains(unrelated.binding))
    }

    func testAtomicOriginalPREWindowYieldsWithoutRenewingOuterBudget() throws {
        let f = try Fixture()
        let a = try f.item()
        var head = try f.commit(changes: [(a, true)])
        for _ in 0..<8 { head = try f.commit(parents: [head.binding]) }
        let draft = try f.commit(parents: [head.binding], admit: false)
        let walk = try AtomicAuthorityOriginalPRE(index: f.index, source: .legacy(draft), target: a.target)
        defer { try? walk.close() }
        f.index.graphMaximumVMInstructions = 6000
        var result: AuthorityStore.HistoricalEligibility?
        var yieldedForAllowance = false
        try f.index.withCatalogueScanBudget {
            for _ in 0..<128 {
                let before = walk.processedUnits
                result = try walk.step(maximumUnits: 1)
                if result != nil { break }
                if before == walk.processedUnits {
                    yieldedForAllowance = true
                    break
                }
            }
        }
        XCTAssertNil(result)
        XCTAssertTrue(yieldedForAllowance)
        XCTAssertGreaterThan(walk.processedUnits, 0)
        XCTAssertLessThan(f.index.lastCatalogueScanWorkForTesting, 6000)
        let progressed = walk.processedUnits
        f.index.graphMaximumVMInstructions = 200_000_000
        for _ in 0..<128 where result == nil { result = try walk.step(maximumUnits: 1) }
        XCTAssertEqual(result, .eligible)
        XCTAssertGreaterThan(walk.processedUnits, progressed)
        try walk.close()
        XCTAssertEqual(try f.count("authority_control_work"), 0)
    }
    private struct Item {
        let original: AuthorityRevision
        let row: ItemIndex.CatalogueRow
        var id: String { original.revision.revisionID }
        var target: AuthorityStore.Target {
            try! .init(itemID: original.revision.itemID, revisionID: id, sha256: original.sha256)
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
                "authority-control-" + Identifier.make())
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            index = try ItemIndex(path: root.appendingPathComponent("index.sqlite").path, create: true)
            index.graphReserveBytes = UInt64(AttachmentFixtureCapacity.reserveBytes)
            try index.validateRecoveryGraph(requireLinearProjection: false)
            try transaction {
                try index.initializeAuthoritySchema()
                try index.initializeAuthorityControlSchema()
            }
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
            var size = UInt64(bytes.count + 4096)
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
            else { throw TractandaError("resourceLimit", "Fixture size unavailable.") }
            while let u = e.nextObject() as? URL {
                size += UInt64(try u.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            }
            guard size < Self.cap else {
                throw TractandaError("resourceLimit", "Fixture estimate exceeds cap.")
            }
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
            return try FileMetadata.read(at: url)
        }
        func item(
            parent: Item? = nil, subject: String = "original", at: String? = nil, revisionID: String? = nil,
            provenance: RevisionProvenance? = nil, classID: String = "Item",
            changes: [String: ItemValue] = [:]
        ) throws -> Item {
            var fields =
                try parent?.original.revision.fields ?? [
                    "itemID": .text(try id()), "classID": .text(classID), "schemaVersion": .integer(1),
                    "createdAt": .date("2026-10-14T12:00:00.000Z"),
                ]
            let rid = try revisionID ?? id()
            fields["revisionID"] = .text(rid)
            fields["subject"] = .text(subject)
            fields["actor"] = .text("user:fixture")
            fields["operationID"] = .text(try id())
            fields["requestIdentity"] = .text("fixture")
            fields["modifiedAt"] = .date(
                try at ?? parent.map {
                    try RevisionPublicationClock.after(
                        [$0.original.revision.modifiedAt], now: { "2026-10-14T12:00:00.000Z" })
                } ?? "2026-10-14T12:00:00.000Z")
            fields.removeValue(forKey: "revisionAncestry")
            if let parent { fields["supersedes"] = .text(parent.id) }
            if let provenance, provenance.parents.count != 1 { fields.removeValue(forKey: "supersedes") }
            for (key, value) in changes { fields[key] = value }
            fields["revisionAncestry"] = try
                (provenance
                ?? .init(
                    kind: .authored, originReplicaID: origin, parents: parent.map { [$0.id] } ?? [],
                    writtenFields: parent == nil
                        ? fields.keys.filter { !RevisionMerge.managedFields.contains($0) }.sorted()
                        : ["subject"], unsetFields: [], frontier: [])).itemValue
            let value = try Revision(fields: fields, formatVersion: 2)
            let original = try AuthorityRevision(originalBytes: RecordCodec.encode(value))
            let path = "items/2026/10/14/12/00/" + value.itemID + "/" + rid + ".tractanda"
            let meta = try write(original.originalBytes, path: path)
            let row = ItemIndex.CatalogueRow(
                revisionID: rid, itemID: value.itemID, path: path, parentID: value.supersedes,
                actor: "user:fixture", operationID: fields["operationID"]!.string!, size: meta.size,
                inode: meta.inode, uid: meta.uid, mode: meta.mode,
                modificationSeconds: meta.modificationSeconds,
                modificationNanoseconds: meta.modificationNanoseconds,
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
        func append(_ item: Item, parent: Item? = nil, control: AuthorityBinding? = nil) throws {
            try index.setAuthorityDisposition(
                id: item.id, evaluation: .init(disposition: .eligible, reason: "Verified fixture."))
            try index.appendValidatedPeer(
                row: item.row, revision: item.original, parent: parent?.original, control: control)
        }
        func control(
            _ kind: AuthorityRecord.Kind, payload: [String: ItemValue], parents: [AuthorityBinding] = [],
            origin: String? = nil
        ) throws -> AuthorityRecordCodec.Verified {
            let record = try AuthorityRecord(
                recordID: id(), storeID: store, originReplicaID: origin ?? id(), kind: kind,
                parentAuthorityIDs: Array(Set(parents.map(\.recordID))).sorted(), actorPrincipal: "fixture",
                createdAt: "2026-10-14T12:00:00.000Z", payload: payload)
            let verified = try AuthorityRecordCodec.decode(AuthorityRecordCodec.encode(record))
            let path = "authority/" + record.recordID + ".tractanda"
            _ = try write(verified.originalBytes, path: path)
            try index.retainAuthorityObject(
                .init(
                    descriptor: .init(
                        kind: .authority, id: record.recordID, length: verified.originalBytes.count,
                        sha256: verified.sha256), path: path, packageID: package, peerID: "fixture",
                    configurationDigest: String(repeating: "a", count: 64), permittedOrigin: true),
                revision: nil, authority: verified)
            return verified
        }
        func commit(
            parents: [AuthorityBinding] = [], changes: [(Item, Bool)] = [], origin: String? = nil,
            admit: Bool = true, localParent: AuthorityBinding? = nil,
            effects: [AuthorityStore.DispositionDelta]? = nil
        ) throws -> AuthorityStore.VerifiedControlPlan {
            let deltas =
                effects
                ?? changes.sorted { $0.0.id < $1.0.id }.map { item, eligible in
                    AuthorityStore.DispositionDelta(
                        target: item.target, eligible: eligible, actor: "fixture", policyIDs: [])
                }
            let c = try control(
                .controlCommit,
                payload: [
                    "controls": .list(parents.sorted { $0.recordID < $1.recordID }.map(\.itemValue)),
                    "deltas": .list(deltas.map(\.itemValue)), "bootstrap": .list([]),
                    "localParent": .list(localParent.map { [$0.itemValue] } ?? []),
                ], parents: parents, origin: origin)
            let plan = try AuthorityStore.VerifiedControlPlan(control: c)
            if admit { try index.retainValidatedControl(plan) }
            return plan
        }
        func expose(_ item: Item, cut: AuthorityBinding, cause: String? = nil, locallyVisible: Bool = true)
            throws
            -> AuthorityStore.VerifiedExposurePlan
        {
            let c = try control(
                .visibilityWitness,
                payload: [
                    "target": item.target.itemValue, "cut": cut.itemValue,
                    "modifiedAt": .date(item.original.revision.modifiedAt),
                    "causeKey": .list(cause.map { [.text($0)] } ?? []),
                ], parents: [cut])
            let plan = try AuthorityStore.VerifiedExposurePlan(witness: c)
            try index.retainValidatedExposure(plan, revision: item.original, locallyVisible: locallyVisible)
            return plan
        }
        func evidence(_ item: Item) throws -> AuthorityRecordCodec.Verified {
            let p = try item.original.revision.provenance!
            return try control(
                .authoredEvidence,
                payload: [
                    "target": item.target.itemValue, "sourceControl": .list([]),
                    "parents": .list(p.parents.map(ItemValue.text)),
                    "frontier": .list(p.parents.map(ItemValue.text)), "itemPolicies": .list([]),
                    "admissionPolicies": .list([]), "principal": .text("fixture"), "sourceUID": .integer(0),
                    "groups": .object([:]), "aliases": .object([:]), "rights": .list([.text("write")]),
                    "evaluated": .boolean(true),
                    "intent": .object([
                        "writtenFields": .list(p.writtenFields.map(ItemValue.text)),
                        "unsetFields": .list(p.unsetFields.map(ItemValue.text)),
                    ]), "acceptedAuthority": .list([]),
                ], origin: p.originReplicaID)
        }
        func reservation(
            _ item: Item, cause: AuthorityBinding, exposure: AuthorityStore.VerifiedExposurePlan,
            floor: String? = nil, fields: [String: ItemValue]? = nil
        )
            throws -> AuthorityStore.VerifiedReconciliationPlan
        {
            let e = try AuthorityBinding(
                recordID: exposure.witness.record.recordID, sha256: exposure.witness.sha256)
            let c = try control(
                .reconciliationWitness,
                payload: [
                    "itemID": .text(item.original.revision.itemID), "parents": .list([.text(item.id)]),
                    "frontier": .list([.text(item.id)]), "causes": .list([cause.itemValue]),
                    "exposures": .list([e.itemValue]), "baseFloor": .date(floor ?? exposure.modifiedAt),
                    "modifiedAt": .date(
                        RevisionPublicationClock.after(
                            [floor ?? exposure.modifiedAt], now: { "2026-10-14T12:00:00.000Z" })),
                    "outputRevisionID": .text(id()),
                    "planDigest": .text(
                        index.authorityReconciliationPlanDigest(
                            fields: fields ?? RevisionMerge.semanticFields(item.original.revision))),
                ], parents: [cause, e])
            return try .init(witness: c)
        }
        func count(_ table: String) throws -> Int64 {
            let s = try index.corpusPrepare("SELECT COUNT(*) FROM " + table)
            defer { sqlite3_finalize(s) }
            guard index.catalogueStep(s) == SQLITE_ROW else { throw index.graphSQLiteError() }
            return sqlite3_column_int64(s, 0)
        }
    }
    private func code(_ expected: String, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body()) { XCTAssertEqual(($0 as? TractandaError)?.code, expected) }
    }
    func testExactCutsAndMaximalHoldAcrossDiamondPreserveOldCut() throws {
        let f = try Fixture()
        try f.transaction {
            let a = try f.item()
            let accepted = try f.commit(changes: [(a, true)])
            let hold = try f.commit(parents: [accepted.binding], changes: [(a, false)])
            let independent = try f.commit(parents: [accepted.binding])
            let merged = try f.commit(parents: [hold.binding, independent.binding])
            XCTAssertEqual(try f.index.eligibilityAtCut(revisionID: a.id, cut: merged.binding), .held)
            let approved = try f.commit(parents: [merged.binding], changes: [(a, true)])
            XCTAssertEqual(try f.index.eligibilityAtCut(revisionID: a.id, cut: approved.binding), .eligible)
            XCTAssertEqual(try f.index.eligibilityAtCut(revisionID: a.id, cut: accepted.binding), .eligible)
            XCTAssertEqual(try f.index.eligibilityAtCut(revisionID: a.id, cut: hold.binding), .held)
            XCTAssertEqual(try f.count("authority_control_work"), 0)
        }
    }
    func testOutOfOrderControlsAndKnownDeliveryReachQuiescence() throws {
        let f = try Fixture()
        try f.transaction {
            let a = try f.item()
            let parent = try f.commit(changes: [(a, true)], admit: false)
            let child = try f.commit(parents: [parent.binding], admit: false)
            code("invalidAuthority") { try f.index.retainValidatedControl(child) }
            XCTAssertEqual(
                try f.index.authorityReadyControlPage(packageID: f.package).map { $0.descriptor.id },
                [parent.binding.recordID])
            try f.index.retainValidatedControl(parent)
            try f.index.retainValidatedControl(child)
            for _ in 0..<4 {
                try f.index.retainValidatedControl(parent)
                try f.index.retainValidatedControl(child)
            }
            XCTAssertEqual(try f.count("authority_control"), 2)
            XCTAssertTrue(try f.index.authorityReadyControlPage(packageID: f.package).isEmpty)
            XCTAssertEqual(try f.index.authorityControlParents(child.binding), [parent.binding])
        }
    }
    func testOriginChainForkFailsClosedAndReversePagesBoundBeforeDecode() throws {
        let f = try Fixture()
        try f.transaction {
            let a = try f.item()
            let first = try f.commit(changes: [(a, true)], origin: f.origin)
            XCTAssertTrue(try f.index.authorityLocallyAccepted(revisionID: a.id, originID: f.origin))
            XCTAssertFalse(try f.index.authorityLocallyAccepted(revisionID: a.id, originID: f.id()))
            let skipped = try f.commit(origin: f.origin, admit: false)
            code("invalidAuthority") { try f.index.retainValidatedControl(skipped) }
            XCTAssertEqual(try f.index.authorityControlHead(originID: f.origin), first.binding)
            for _ in 0..<3 {
                let next = try f.item()
                _ = try f.commit(changes: [(next, true)])
            }
            f.index.graphMaximumPageBytes = 180
            var after: String?
            var all: [String] = []
            while true {
                let page = try f.index.affectedAuthorityItemPage(
                    kind: "actor", value: "fixture", after: after)
                if page.isEmpty { break }
                all += page
                after = page.last
            }
            XCTAssertEqual(all.count, 4)
            f.index.graphMaximumPageBytes = 1
            code("resourceLimit") {
                _ = try f.index.affectedAuthorityItemPage(kind: "actor", value: "fixture")
            }
        }
    }
    func testDemotionRetainsVisiblePhysicalHistoryAndSourcePolicyFrontier() throws {
        let f = try Fixture()
        try f.transaction {
            let a = try f.item()
            try f.append(a)
            let b = try f.item(parent: a, subject: "later", at: "2026-10-14T12:10:00.000Z")
            try f.append(b, parent: a)
            let accepted = try f.commit(changes: [(a, true), (b, true)])
            let bExposure = try f.expose(b, cut: accepted.binding)
            let neverExposed = try f.item(parent: a, subject: "pending")
            let passes = f.index.graphValidationPassesForTesting
            XCTAssertEqual(
                try f.index.authorityItemFrontierAtCut(itemID: a.target.itemID, cut: accepted.binding), [b.id]
            )
            let held = try f.commit(parents: [accepted.binding], changes: [(b, false)])
            try f.index.setAuthorityDisposition(
                id: b.id, evaluation: .init(disposition: .held, reason: "Verified revocation."))
            try f.index.reconcileAuthorityAcceptedItem(itemID: a.target.itemID)
            XCTAssertEqual(
                Set(try f.index.authorityChildPage(parentID: a.id).map { $0.descriptor.id }),
                Set([b.id, neverExposed.id]))
            XCTAssertNil(try f.index.revision(b.id))
            XCTAssertNotNil(try f.index.revision(a.id))
            XCTAssertTrue(try f.index.acceptedGraphProofIsCurrent())
            XCTAssertEqual(f.index.graphValidationPassesForTesting, passes)
            XCTAssertEqual(
                try f.index.authorityItemFrontierAtCut(itemID: a.target.itemID, cut: held.binding), [a.id])
            _ = try f.expose(a, cut: accepted.binding)
            XCTAssertTrue(try f.index.authorityHasLocalHistoryAdmission(revisionID: b.id))
            XCTAssertEqual(try f.index.authorityExposure(revisionID: b.id)?.target.revisionID, b.id)
            XCTAssertFalse(try f.index.authorityHasLocalHistoryAdmission(revisionID: neverExposed.id))
            let page = try f.index.authorityHistoricalPage(itemID: a.target.itemID, limit: 1)
            XCTAssertEqual(page.map { $0.descriptor.id }, [b.id])
            XCTAssertEqual(
                try f.index.authorityHistoricalPage(itemID: a.target.itemID, afterRevisionID: b.id).map {
                    $0.descriptor.id
                }, [a.id])
            XCTAssertEqual(
                try Data(contentsOf: f.root.appendingPathComponent(b.row.path)), b.original.originalBytes)
            XCTAssertEqual(
                try f.index.authorityHeldReceipts(operationID: b.row.operationID, originID: f.origin).map {
                    $0.descriptor.id
                }, [b.id])
            try f.index.clearAuthorityControlDerivedState()
            try f.index.retainValidatedControl(accepted)
            try f.index.retainValidatedControl(held)
            try f.index.retainValidatedExposure(bExposure, revision: b.original, locallyVisible: true)
            XCTAssertTrue(try f.index.authorityHasLocalHistoryAdmission(revisionID: b.id))
            XCTAssertEqual(
                try f.index.authorityExposureFloor(itemID: a.target.itemID)?.target.revisionID, b.id)
            XCTAssertEqual(
                try f.index.authorityHistoricalPage(itemID: a.target.itemID, limit: 1).first?.descriptor.id,
                b.id)
        }
    }
    func testDemotionRejectsStillEligibleDescendantAndRollsBack() throws {
        let f = try Fixture()
        try f.transaction {
            let a = try f.item()
            try f.append(a)
            let b = try f.item(parent: a)
            try f.append(b, parent: a)
            try f.index.setAuthorityDisposition(
                id: a.id, evaluation: .init(disposition: .held, reason: "Must hold descendants first."))
            code("invalidAuthority") { try f.index.reconcileAuthorityAcceptedItem(itemID: a.target.itemID) }
            XCTAssertNotNil(try f.index.revision(a.id))
            XCTAssertNotNil(try f.index.revision(b.id))
        }
    }
    func testReservationDeduplicatesWithoutUsingEquivalentOutputClock() throws {
        let f = try Fixture()
        try f.transaction {
            let a = try f.item()
            try f.append(a)
            let cut = try f.commit(changes: [(a, true)])
            let exposure = try f.expose(a, cut: cut.binding)
            let plan = try f.reservation(a, cause: cut.binding, exposure: exposure)
            let inventedFloor = try f.reservation(
                a, cause: cut.binding, exposure: exposure, floor: "2099-01-01T00:00:00.000Z")
            code("invalidAuthority") { _ = try f.index.reserveReconciliation(inventedFloor) }
            let first = try f.index.reserveReconciliation(plan)
            let equivalent = try f.reservation(a, cause: cut.binding, exposure: exposure)
            try f.index.retainValidatedReconciliation(equivalent)
            let beforeControls = try f.count("authority_control")
            let beforeObjects = try f.count("authority_objects")
            for _ in 0..<3 { try f.index.retainValidatedReconciliation(equivalent) }
            XCTAssertEqual(try f.count("authority_reconciliation_witness"), 2)
            XCTAssertEqual(try f.count("authority_control"), beforeControls)
            XCTAssertEqual(try f.count("authority_objects"), beforeObjects)
            XCTAssertEqual(try f.index.reserveReconciliation(equivalent), first)
            XCTAssertEqual(try f.count("authority_reconciliation"), 1)
            let p = try RevisionProvenance(
                kind: .automaticMerge, originReplicaID: plan.witness.record.originReplicaID, parents: [a.id],
                writtenFields: [],
                unsetFields: [], frontier: [a.id], mergeProfile: AuthorityStore.reconciliationProfile,
                authorityWitness: first.witness)
            let output = try f.item(
                parent: a, at: plan.modifiedAt, revisionID: first.revisionID, provenance: p)
            try f.index.validateAuthorityReconciliationMetadata(output.original.revision)
            var forged = output.original.revision.fields
            forged["subject"] = .text("unearned value")
            code("invalidAuthority") {
                try f.index.validateAuthorityReconciliationMetadata(
                    Revision(fields: forged, formatVersion: 2))
            }
            try f.index.setAuthorityDisposition(
                id: output.id, evaluation: .init(disposition: .eligible, reason: "Validated output."))
            try f.index.insertRecoveryRow(output.row, graphFields: output.original.revision.fields)
            _ = try f.index.appendAcceptedGraphBookkeeping(row: output.row, parents: [a.id], feedback: [])
            try f.index.advanceAcceptedGraphProof()
            try f.index.completeReconciliation(first, revision: output.original)
            let remoteWitness = try AuthorityBinding(
                recordID: equivalent.witness.record.recordID, sha256: equivalent.witness.sha256)
            let remoteProvenance = try RevisionProvenance(
                kind: .automaticMerge, originReplicaID: equivalent.witness.record.originReplicaID,
                parents: [a.id], writtenFields: [], unsetFields: [], frontier: [a.id],
                mergeProfile: AuthorityStore.reconciliationProfile, authorityWitness: remoteWitness)
            let remoteOutput = try f.item(
                parent: a, at: equivalent.modifiedAt, revisionID: equivalent.outputRevisionID,
                provenance: remoteProvenance)
            try f.index.validateAuthorityReconciliationMetadata(remoteOutput.original.revision)
            XCTAssertNotEqual(remoteOutput.id, output.id)
            let causeKey = try f.index.authorityReconciliationCauseKey(
                itemID: a.target.itemID, frontier: [a.id], causes: [cut.binding])
            let outputCut = try f.commit(parents: [cut.binding], changes: [(output, true)])
            _ = try f.expose(output, cut: outputCut.binding, cause: causeKey)
            XCTAssertEqual(
                try f.index.authorityExposureFloor(itemID: a.target.itemID)?.target.revisionID, output.id)
            XCTAssertEqual(
                try f.index.authorityExposureFloor(itemID: a.target.itemID, excludingCauseKey: causeKey)?
                    .target.revisionID, a.id)
        }
    }
    func testImportedSourceVisibilityDoesNotAdmitLocalHistoryOrAdvanceLocalClock() throws {
        let f = try Fixture()
        try f.transaction {
            let a = try f.item()
            try f.append(a)
            let held = try f.item(parent: a, subject: "source only", at: "2099-01-01T00:00:00.000Z")
            let sourceCut = try f.commit(changes: [(a, true), (held, true)])
            try f.index.setAuthorityDisposition(
                id: held.id, evaluation: .init(disposition: .held, reason: "Not admitted by this receiver."))
            let sourceExposure = try f.expose(held, cut: sourceCut.binding, locallyVisible: false)
            XCTAssertNotNil(try f.index.authorityExposure(revisionID: held.id))
            XCTAssertFalse(try f.index.authorityHasLocalHistoryAdmission(revisionID: held.id))
            XCTAssertNil(try f.index.authorityExposureFloor(itemID: a.target.itemID))
            XCTAssertEqual(
                try f.index.authorityHistoricalPage(itemID: a.target.itemID).map { $0.descriptor.id }, [a.id])
            let foreign = try f.reservation(a, cause: sourceCut.binding, exposure: sourceExposure)
            let controls = try f.count("authority_control")
            try f.index.retainValidatedReconciliation(foreign)
            let witness = try AuthorityBinding(
                recordID: foreign.witness.record.recordID, sha256: foreign.witness.sha256)
            let p = try RevisionProvenance(
                kind: .automaticMerge, originReplicaID: foreign.witness.record.originReplicaID,
                parents: [a.id], writtenFields: [], unsetFields: [], frontier: [a.id],
                mergeProfile: AuthorityStore.reconciliationProfile, authorityWitness: witness)
            let c = try f.item(
                parent: a, at: foreign.modifiedAt, revisionID: foreign.outputRevisionID, provenance: p)
            try f.index.validateAuthorityReconciliationMetadata(c.original.revision)
            XCTAssertEqual(try f.count("authority_control"), controls)
            XCTAssertEqual(try f.count("authority_reconciliation"), 0)
            XCTAssertEqual(try f.count("authority_local_exposure"), 0)
            XCTAssertNil(try f.index.authorityExposureFloor(itemID: a.target.itemID))
            XCTAssertFalse(try f.index.authorityHasLocalHistoryAdmission(revisionID: c.id))
            let before = try f.count("authority_control")
            try f.index.retainLocalAssessedMaterialization(c.original, packageID: f.package)
            XCTAssertTrue(try f.index.authorityHasLocalHistoryAdmission(revisionID: c.id))
            XCTAssertFalse(try f.index.authorityLocallyExposed(revisionID: c.id))
            XCTAssertNil(try f.index.authorityExposureFloor(itemID: a.target.itemID))
            XCTAssertEqual(try f.count("authority_control"), before)
            let work = try XCTUnwrap(f.index.authorityLocalVisibilityWorkPage().first)
            try f.index.clearAuthorityLocalVisibilityWork(itemID: work.itemID, token: work.token)
            try f.index.retainLocalAssessedMaterialization(c.original, packageID: f.package)
            XCTAssertTrue(try f.index.authorityLocalVisibilityWorkPage().isEmpty)
            try f.index.clearAuthorityControlDerivedState()
            XCTAssertEqual(try f.count("authority_local_assessment"), 0)
            XCTAssertFalse(try f.index.authorityHasLocalHistoryAdmission(revisionID: c.id))
            XCTAssertTrue(try f.index.authorityLocalVisibilityWorkPage().isEmpty)
            try f.index.retainLocalAssessedMaterialization(c.original, packageID: f.package)
            XCTAssertTrue(try f.index.authorityHasLocalHistoryAdmission(revisionID: c.id))
            XCTAssertEqual(try f.index.authorityLocalVisibilityWorkCount(), 1)
            XCTAssertFalse(try f.index.authorityLocallyExposed(revisionID: c.id))
            XCTAssertNil(try f.index.authorityExposureFloor(itemID: a.target.itemID))
            XCTAssertEqual(try f.count("authority_control"), 0)
        }
    }
    func testCheckpointAdmitsOnlyLocallyVisibleHistoryBarrierWithoutActiveRoot() throws {
        for local in [true, false] {
            let f = try Fixture()
            var itemID = ""
            try f.transaction {
                let a = try f.item()
                itemID = a.target.itemID
                if local { try f.append(a) }
                let cut = try f.commit(changes: [(a, true)])
                _ = try f.expose(a, cut: cut.binding, locallyVisible: local)
                try f.index.setAuthorityDisposition(
                    id: a.id, evaluation: .init(disposition: .held, reason: "No eligible ancestor remains."))
                if local { try f.index.reconcileAuthorityAcceptedItem(itemID: itemID) }
                XCTAssertEqual(try f.index.authorityHistoricalCount(itemID: itemID), local ? 1 : 0)
                XCTAssertEqual(try f.index.authorityRetiredItemPage(), local ? [itemID] : [])
                let barrier = ItemState(
                    itemID: itemID, stateToken: "fixture.history", status: .reviewRequired,
                    representativeRevisionID: nil, frontier: nil, detailsComplete: false)
                try f.index.replaceCurrentProjection(
                    snapshot: nil, state: barrier, policies: [], policiesComplete: false)
                XCTAssertEqual(try f.index.hasCompleteCurrentProjectionCheckpoint(), local)
                if local {
                    try f.index.execute(
                        "UPDATE current_projection SET representative_digest='corrupt' WHERE item=?", [itemID]
                    )
                    XCTAssertFalse(try f.index.hasCompleteCurrentProjectionCheckpoint())
                    try f.index.replaceCurrentProjection(
                        snapshot: nil, state: barrier, policies: [], policiesComplete: false)
                }
            }
            let reopened = try ItemIndex(
                path: f.root.appendingPathComponent("index.sqlite").path, create: false)
            defer { reopened.close() }
            XCTAssertEqual(try reopened.hasCompleteCurrentProjectionCheckpoint(), local)
        }
    }
    func testRecoveryProvisionalWitnessHandlesReversedRowsAndRejectsForgedParentsOrPayload() throws {
        for validPayload in [true, false] {
            let f = try Fixture()
            try f.transaction {
                let a = try f.item()
                try f.index.setAuthorityDisposition(
                    id: a.id,
                    evaluation: .init(disposition: .eligible, reason: "Recovery verified eligibility."))
                let cut = try f.commit(changes: [(a, true)])
                let exposure = try f.expose(a, cut: cut.binding, locallyVisible: false)
                var fields = RevisionMerge.semanticFields(a.original.revision)
                if !validPayload { fields["subject"] = .text("forged zero-write value") }
                let plan = try f.reservation(a, cause: cut.binding, exposure: exposure, fields: fields)
                f.index.invalidateRevisionGraphValidation()
                code("invalidAuthority") { try f.index.retainValidatedReconciliation(plan) }
                code("invalidAuthority") { try f.index.retainRecoveryReconciliation(plan, parents: []) }
                var changed = a.original.revision.fields
                changed["subject"] = .text("wrong retained bytes")
                let wrong = try AuthorityRevision(
                    originalBytes: RecordCodec.encode(Revision(fields: changed, formatVersion: 2)))
                code("invalidAuthority") { try f.index.retainRecoveryReconciliation(plan, parents: [wrong]) }
                try f.index.retainRecoveryReconciliation(plan, parents: [a.original])
                let witness = try AuthorityBinding(
                    recordID: plan.witness.record.recordID, sha256: plan.witness.sha256)
                let p = try RevisionProvenance(
                    kind: .automaticMerge, originReplicaID: plan.witness.record.originReplicaID,
                    parents: [a.id], writtenFields: [], unsetFields: [], frontier: [a.id],
                    mergeProfile: AuthorityStore.reconciliationProfile, authorityWitness: witness)
                let c = try f.item(
                    parent: a, subject: validPayload ? "original" : "forged zero-write value",
                    at: plan.modifiedAt, revisionID: plan.outputRevisionID, provenance: p)
                try f.index.setAuthorityDisposition(
                    id: c.id,
                    evaluation: .init(disposition: .eligible, reason: "Recovery verified source closure."))
                // Deliberately restore the child before its actual parent.
                try f.index.insertRecoveryRow(c.row, graphFields: c.original.revision.fields)
                try f.index.insertRecoveryRow(a.row, graphFields: a.original.revision.fields)
                try f.index.validateRecoveryGraph(requireLinearProjection: false)
                XCTAssertFalse(try f.index.authorityRecoveryProjectionIsComplete())
                var limits = RevisionProjection.Limits()
                limits.minimumFreeBytes = UInt64(AttachmentFixtureCapacity.reserveBytes)
                let analyze = {
                    try f.index.analyzeRevisionProjection(
                        itemID: a.target.itemID,
                        loadVerified: { row in
                            try PooledCanonicalRecord.read(row: row, root: f.root, ownerUID: row.uid)
                        }, limits: limits)
                }
                if validPayload {
                    let snapshot = try analyze()
                    XCTAssertEqual(
                        snapshot.analysis.fields, RevisionMerge.semanticFields(a.original.revision))
                    XCTAssertTrue(try f.index.authorityRecoveryProjectionIsComplete())
                } else {
                    code("invalidRevisionGraph") { _ = try analyze() }
                    XCTAssertFalse(try f.index.authorityRecoveryProjectionIsComplete())
                }
            }
        }
    }
    func testPendingDemotionEntersNextRealPublicationPreCutWithoutAcknowledgements() throws {
        let f = try Fixture()
        try f.transaction {
            let a = try f.item()
            try f.append(a)
            func configuration(_ writer: Bool) -> ItemValue {
                .object([
                    "profile": .text(AccessConfiguration.profile),
                    "users": .list((writer ? ["admin", "fixture"] : ["admin"]).map(ItemValue.text)),
                    "administration": .text("system"),
                ])
            }
            func existingPolicy(_ item: Item) throws {
                // Already authorized policy history: this fixture tests the causal
                // consequence queue, not the Store's administrator admission path.
                try f.index.setAuthorityDisposition(
                    id: item.id,
                    evaluation: .init(disposition: .eligible, reason: "Authorized existing policy fixture."))
                try f.index.insertRecoveryRow(item.row, graphFields: item.original.revision.fields)
                try f.index.validateRecoveryGraph(requireLinearProjection: false)
            }
            let initial = try f.item(
                classID: AccessConfiguration.classID,
                changes: ["isDeleted": .boolean(false), "accessConfiguration": configuration(true)])
            try existingPolicy(initial)
            let beforeB = try f.commit(changes: [(a, true), (initial, true)], origin: f.origin)
            let b = try f.item(parent: a, subject: "concurrent B")
            try f.append(b, parent: a)
            let base = try f.commit(
                parents: [beforeB.binding], changes: [(b, true)], origin: f.origin,
                localParent: beforeB.binding)
            let intent = try RevisionProvenance(
                kind: .authored, originReplicaID: f.id(), parents: [initial.id],
                writtenFields: ["accessConfiguration"], unsetFields: [], frontier: [])
            let policy = try f.item(
                parent: initial, provenance: intent, changes: ["accessConfiguration": configuration(false)])
            try existingPolicy(policy)
            let r = try f.commit(parents: [beforeB.binding], changes: [(policy, true)])
            XCTAssertEqual(try f.index.eligibilityAtCut(revisionID: b.id, cut: r.binding), .unknown)
            let effect = AuthorityStore.DispositionDelta(
                target: b.target, eligible: false, actor: "fixture", policyIDs: [], causes: [r.binding])
            let controls = try f.count("authority_control")
            try f.index.noteAuthorityDispositionEffect(effect)
            try f.index.noteAuthorityDispositionEffect(effect)
            XCTAssertEqual(try f.count("authority_control"), controls)
            XCTAssertEqual(try f.index.authorityDispositionEffectPage(), [effect])
            try f.index.setAuthorityDisposition(
                id: b.id, evaluation: .init(disposition: .held, reason: "Validated R consequence."))
            try f.index.reconcileAuthorityAcceptedItem(itemID: a.target.itemID)
            let pre = try f.commit(
                parents: [base.binding, r.binding], origin: f.origin, localParent: base.binding,
                effects: [effect])
            XCTAssertEqual(try f.index.eligibilityAtCut(revisionID: b.id, cut: pre.binding), .held)
            try f.index.clearAuthorityDispositionEffects(coveredBy: pre.binding, originID: f.origin)
            XCTAssertTrue(try f.index.authorityDispositionEffectPage().isEmpty)
            let unrelated = try f.item(subject: "unrelated real write")
            try f.append(unrelated)
            _ = try f.commit(
                parents: [pre.binding], changes: [(unrelated, true)], origin: f.origin,
                localParent: pre.binding)
            XCTAssertEqual(try f.index.eligibilityAtCut(revisionID: b.id, cut: pre.binding), .held)
        }
    }
    func testPendingEffectsRollbackReplayAndOldControlCannotClearNewerEffect() throws {
        let f = try Fixture()
        var b: Item!
        var base: AuthorityStore.VerifiedControlPlan!
        var r: AuthorityStore.VerifiedControlPlan!
        try f.transaction {
            b = try f.item()
            try f.append(b)
            base = try f.commit(changes: [(b, true)], origin: f.origin)
            r = try f.commit(parents: [base.binding])
        }
        let first = AuthorityStore.DispositionDelta(
            target: b.target, eligible: false, actor: "fixture", policyIDs: [], causes: [r.binding])
        code("cancelled") {
            try f.transaction {
                try f.index.noteAuthorityDispositionEffect(first)
                throw TractandaError("cancelled", "Unpublished transaction.")
            }
        }
        XCTAssertTrue(try f.index.authorityDispositionEffectPage().isEmpty)
        try f.transaction {
            try f.index.noteAuthorityDispositionEffect(first)
            let c1 = try f.commit(
                parents: [base.binding, r.binding], origin: f.origin, localParent: base.binding,
                effects: [first])
            let r2 = try f.commit(parents: [r.binding])
            let newer = AuthorityStore.DispositionDelta(
                target: b.target, eligible: false, actor: "fixture", policyIDs: [], causes: [r2.binding])
            try f.index.noteAuthorityDispositionEffect(newer)
            try f.index.clearAuthorityDispositionEffects(coveredBy: c1.binding, originID: f.origin)
            XCTAssertEqual(try f.index.authorityDispositionEffectPage(), [newer])
            let c2 = try f.commit(
                parents: [c1.binding, r2.binding], origin: f.origin, localParent: c1.binding, effects: [newer]
            )
            code("invalidAuthority") {
                try f.index.clearAuthorityDispositionEffects(coveredBy: c1.binding, originID: f.origin)
            }
            XCTAssertEqual(try f.index.authorityDispositionEffectPage(), [newer])
            try f.index.clearAuthorityDispositionEffects(coveredBy: c2.binding, originID: f.origin)
            let before = try f.count("authority_control")
            // Replay uses the exact recovered local cut rather than regenerating an
            // already held effect. Re-clearing the same sealed publication is harmless.
            XCTAssertEqual(try f.index.eligibilityAtCut(revisionID: b.id, cut: c2.binding), .held)
            try f.index.clearAuthorityDispositionEffects(coveredBy: c2.binding, originID: f.origin)
            XCTAssertTrue(try f.index.authorityDispositionEffectPage().isEmpty)
            XCTAssertEqual(try f.count("authority_control"), before)
        }
    }
    func testLateDominatedPeerReconciliationUsesOwnParentsAndPreviewRestoresProof() throws {
        let f = try Fixture()
        try f.transaction {
            let a = try f.item()
            try f.append(a)
            let cut = try f.commit(changes: [(a, true)])
            let exposure = try f.expose(a, cut: cut.binding)
            let plan = try f.reservation(a, cause: cut.binding, exposure: exposure)
            let e = try f.item(parent: a, subject: "later E", at: "2026-10-14T12:10:00.000Z")
            try f.append(e, parent: a)
            try f.index.retainValidatedReconciliation(plan)
            let witness = try AuthorityBinding(
                recordID: plan.witness.record.recordID, sha256: plan.witness.sha256)
            let p = try RevisionProvenance(
                kind: .automaticMerge, originReplicaID: plan.witness.record.originReplicaID, parents: [a.id],
                writtenFields: [], unsetFields: [], frontier: [a.id],
                mergeProfile: AuthorityStore.reconciliationProfile, authorityWitness: witness)
            let d = try f.item(
                parent: a, at: plan.modifiedAt, revisionID: plan.outputRevisionID, provenance: p)
            var limits = RevisionProjection.Limits()
            limits.minimumFreeBytes = UInt64(AttachmentFixtureCapacity.reserveBytes)
            let load: (ItemIndex.CatalogueRow) throws -> PooledCanonicalRecord = {
                try PooledCanonicalRecord.read(row: $0, root: f.root, ownerUID: $0.uid)
            }
            let before = try f.index.analyzeRevisionProjection(
                itemID: a.target.itemID, loadVerified: load, limits: limits)
            let passes = f.index.graphValidationPassesForTesting
            try f.index.validatePeerMaterialization(
                row: d.row, revision: d.original, loadVerified: load, limits: limits)
            XCTAssertNil(try f.index.revision(d.id))
            XCTAssertEqual(f.index.lastAnalyzedProjection, before)
            XCTAssertTrue(try f.index.acceptedGraphProofIsCurrent())
            XCTAssertEqual(f.index.graphValidationPassesForTesting, passes)
            try f.index.setAuthorityDisposition(
                id: d.id,
                evaluation: .init(
                    disposition: .eligible, reason: "Validated source authority and own context."))
            let current = try f.index.appendValidatedPeerMaterialization(
                row: d.row, revision: d.original, loadVerified: load, limits: limits)
            XCTAssertEqual(current.analysis.frontier, [e.id])
            XCTAssertEqual(current.analysis.fields["subject"], .text("later E"))
            XCTAssertNotNil(try f.index.revision(d.id))
            XCTAssertEqual(f.index.graphValidationPassesForTesting, passes)
        }
    }
    func testForgedAndCancelledPeerPreviewRestoreSQLAndInMemoryAdmission() throws {
        for forged in [false, true] {
            let f = try Fixture()
            try f.transaction {
                let a = try f.item()
                try f.append(a)
                let cut = try f.commit(changes: [(a, true)])
                let exposure = try f.expose(a, cut: cut.binding)
                var fields = RevisionMerge.semanticFields(a.original.revision)
                if forged { fields["subject"] = .text("forged zero-write payload") }
                let plan = try f.reservation(a, cause: cut.binding, exposure: exposure, fields: fields)
                try f.index.retainValidatedReconciliation(plan)
                let witness = try AuthorityBinding(
                    recordID: plan.witness.record.recordID, sha256: plan.witness.sha256)
                let p = try RevisionProvenance(
                    kind: .automaticMerge, originReplicaID: plan.witness.record.originReplicaID,
                    parents: [a.id], writtenFields: [], unsetFields: [], frontier: [a.id],
                    mergeProfile: AuthorityStore.reconciliationProfile, authorityWitness: witness)
                let d = try f.item(
                    parent: a, subject: forged ? "forged zero-write payload" : "original",
                    at: plan.modifiedAt, revisionID: plan.outputRevisionID, provenance: p)
                var limits = RevisionProjection.Limits()
                limits.minimumFreeBytes = UInt64(AttachmentFixtureCapacity.reserveBytes)
                let ordinaryLoad: (ItemIndex.CatalogueRow) throws -> PooledCanonicalRecord = {
                    try PooledCanonicalRecord.read(row: $0, root: f.root, ownerUID: $0.uid)
                }
                let before = try f.index.analyzeRevisionProjection(
                    itemID: a.target.itemID, loadVerified: ordinaryLoad, limits: limits)
                var loaded = false
                let load: (ItemIndex.CatalogueRow) throws -> PooledCanonicalRecord = { row in
                    let record = try ordinaryLoad(row)
                    if row.revisionID == d.id { loaded = true }
                    return record
                }
                code(forged ? "invalidRevisionGraph" : "cancelled") {
                    try f.index.validatePeerMaterialization(
                        row: d.row, revision: d.original, loadVerified: load, limits: limits,
                        progress: {
                            if !forged && loaded {
                                throw TractandaError("cancelled", "Native preview callback.")
                            }
                        })
                }
                XCTAssertTrue(loaded)
                XCTAssertNil(try f.index.revision(d.id))
                XCTAssertTrue(try f.index.acceptedGraphProofIsCurrent())
                XCTAssertEqual(f.index.lastAnalyzedProjection, before)
                var tiny = limits
                tiny.maximumVMInstructions = 1
                code("resourceLimit") {
                    try f.index.validatePeerMaterialization(
                        row: d.row, revision: d.original, loadVerified: ordinaryLoad, limits: tiny)
                }
                XCTAssertNil(try f.index.revision(d.id))
                XCTAssertTrue(try f.index.acceptedGraphProofIsCurrent())
                XCTAssertEqual(f.index.lastAnalyzedProjection, before)
            }
        }
    }
    func testOrdinaryAutomaticMaterializationsAcceptLateEquivalentOutputsWithoutEvidence() throws {
        let f = try Fixture()
        try f.transaction {
            let r = try f.item()
            try f.append(r)
            let a = try f.item(parent: r, subject: "left")
            try f.append(a, parent: r)
            let bp = try RevisionProvenance(
                kind: .authored, originReplicaID: f.id(), parents: [r.id], writtenFields: ["note"],
                unsetFields: [], frontier: [])
            let b = try f.item(parent: r, provenance: bp, changes: ["note": .text("right")])
            try f.append(b, parent: r)
            let e = try f.item(parent: a, subject: "later E", at: "2026-10-14T12:10:00.000Z")
            try f.append(e, parent: a)
            var limits = RevisionProjection.Limits()
            limits.minimumFreeBytes = UInt64(AttachmentFixtureCapacity.reserveBytes)
            let load: (ItemIndex.CatalogueRow) throws -> PooledCanonicalRecord = {
                try PooledCanonicalRecord.read(row: $0, root: f.root, ownerUID: $0.uid)
            }
            let before = try f.index.analyzeRevisionProjection(
                itemID: r.target.itemID, loadVerified: load, limits: limits)
            let passes = f.index.graphValidationPassesForTesting
            let controls = try f.count("authority_control")
            var outputs: [String] = []
            for at in ["2026-10-14T12:00:00.010Z", "2026-10-14T12:00:00.012Z"] {
                let p = try RevisionProvenance(
                    kind: .automaticMerge, originReplicaID: f.id(), parents: [a.id, b.id].sorted(),
                    writtenFields: [], unsetFields: [], frontier: [a.id, b.id].sorted(),
                    mergeProfile: RevisionMerge.profile)
                let d = try f.item(
                    parent: a, subject: "left", at: at, provenance: p, changes: ["note": .text("right")])
                try f.index.validatePeerMaterialization(
                    row: d.row, revision: d.original, loadVerified: load, limits: limits)
                XCTAssertNil(try f.index.revision(d.id))
                try f.index.setAuthorityDisposition(
                    id: d.id,
                    evaluation: .init(
                        disposition: .eligible, reason: "Source verified zero-write ordinary materialization."
                    ))
                let current = try f.index.appendValidatedPeerMaterialization(
                    row: d.row, revision: d.original, loadVerified: load, limits: limits)
                XCTAssertEqual(current.analysis.frontier, [e.id, b.id].sorted())
                XCTAssertEqual(current.analysis.fields["subject"], .text("later E"))
                XCTAssertEqual(current.analysis.fields["note"], .text("right"))
                outputs.append(d.id)
            }
            XCTAssertNotEqual(outputs[0], outputs[1])
            XCTAssertEqual(try f.count("authority_reconciliation_witness"), 0)
            XCTAssertEqual(try f.count("authority_control"), controls)
            XCTAssertEqual(f.index.graphValidationPassesForTesting, passes)
            XCTAssertEqual(before.analysis.fields["subject"], .text("later E"))
        }
    }
    func testOrdinaryAutomaticRejectsForgedPayloadAndProtectedConcurrentChoices() throws {
        for protected in [false, true] {
            let f = try Fixture()
            try f.transaction {
                let r = try f.item()
                try f.append(r)
                let field = protected ? "isDeleted" : "subject"
                let ap = try RevisionProvenance(
                    kind: .authored, originReplicaID: f.id(), parents: [r.id], writtenFields: [field],
                    unsetFields: [], frontier: [])
                let a = try f.item(
                    parent: r, subject: protected ? "original" : "left", provenance: ap,
                    changes: protected ? ["isDeleted": .boolean(false)] : [:])
                let bp = try RevisionProvenance(
                    kind: .authored, originReplicaID: f.id(), parents: [r.id],
                    writtenFields: [protected ? "isDeleted" : "note"], unsetFields: [], frontier: [])
                let b = try f.item(
                    parent: r, provenance: bp,
                    changes: protected ? ["isDeleted": .boolean(false)] : ["note": .text("right")])
                for item in [a, b] {
                    try f.index.setAuthorityDisposition(
                        id: item.id,
                        evaluation: .init(
                            disposition: .eligible, reason: "Existing authorized parent fixture."))
                    try f.index.insertRecoveryRow(item.row, graphFields: item.original.revision.fields)
                }
                try f.index.validateRecoveryGraph(requireLinearProjection: false)
                let p = try RevisionProvenance(
                    kind: .automaticMerge, originReplicaID: f.id(), parents: [a.id, b.id].sorted(),
                    writtenFields: [], unsetFields: [], frontier: [a.id, b.id].sorted(),
                    mergeProfile: RevisionMerge.profile)
                let d = try f.item(
                    parent: a, subject: protected ? "original" : "forged subject",
                    at: "2026-10-14T12:00:00.010Z", provenance: p,
                    changes: protected ? ["isDeleted": .boolean(false)] : ["note": .text("right")])
                var limits = RevisionProjection.Limits()
                limits.minimumFreeBytes = UInt64(AttachmentFixtureCapacity.reserveBytes)
                code("invalidRevisionGraph") {
                    try f.index.validatePeerMaterialization(
                        row: d.row, revision: d.original,
                        loadVerified: {
                            try PooledCanonicalRecord.read(row: $0, root: f.root, ownerUID: $0.uid)
                        }, limits: limits)
                }
                XCTAssertNil(try f.index.revision(d.id))
                XCTAssertTrue(try f.index.acceptedGraphProofIsCurrent())
            }
        }
    }
    func testSelectedEvidenceSurvivesNormalizedPagesPendingEffectsAndExactCoveredClear() throws {
        let f = try Fixture()
        try f.transaction {
            let b = try f.item()
            let e1 = try f.evidence(b)
            let e2 = try f.evidence(b)
            let first = try AuthorityBinding(recordID: e1.record.recordID, sha256: e1.sha256)
            let second = try AuthorityBinding(recordID: e2.record.recordID, sha256: e2.sha256)
            let cause = try f.commit()
            let d1 = AuthorityStore.DispositionDelta(
                target: b.target, eligible: true, actor: "fixture", policyIDs: [], causes: [cause.binding],
                evidence: first)
            let c1 = try f.commit(parents: [cause.binding], origin: f.origin, effects: [d1])
            XCTAssertEqual(try f.index.authorityControlDeltaPage(c1.binding), [d1])
            let d2 = AuthorityStore.DispositionDelta(
                target: b.target, eligible: true, actor: "fixture", policyIDs: [], causes: [cause.binding],
                evidence: second)
            try f.index.noteAuthorityDispositionEffect(d2)
            XCTAssertEqual(try f.index.authorityDispositionEffectPage(), [d2])
            try f.index.clearAuthorityDispositionEffects(coveredBy: c1.binding, originID: f.origin)
            XCTAssertEqual(try f.index.authorityDispositionEffectPage().first?.evidence, second)
            let c2 = try f.commit(
                parents: [c1.binding], origin: f.origin, localParent: c1.binding, effects: [d2])
            try f.index.clearAuthorityDispositionEffects(coveredBy: c2.binding, originID: f.origin)
            XCTAssertTrue(try f.index.authorityDispositionEffectPage().isEmpty)
            XCTAssertEqual(try f.index.authorityControlDeltaPage(c2.binding).first?.evidence, second)
            XCTAssertEqual(try f.index.eligibilityAtCut(revisionID: b.id, cut: c2.binding), .eligible)
            let denial = AuthorityStore.DispositionDelta(
                target: b.target, eligible: false, actor: "fixture", policyIDs: [], causes: [cause.binding])
            let c3 = try f.commit(
                parents: [c2.binding], origin: f.origin, localParent: c2.binding, effects: [denial])
            XCTAssertNil(try f.index.authorityControlDeltaPage(c3.binding).first?.evidence)
            XCTAssertEqual(try f.index.eligibilityAtCut(revisionID: b.id, cut: c3.binding), .held)
        }
    }
    func testLocalAcceptedNeverReadyHistoryDoesNotInventExposureOrImportSourceHistory() throws {
        for local in [false, true] {
            let f = try Fixture()
            try f.transaction {
                let b = try f.item()
                let e = try f.evidence(b)
                let evidence = try AuthorityBinding(recordID: e.record.recordID, sha256: e.sha256)
                let delta = AuthorityStore.DispositionDelta(
                    target: b.target, eligible: true, actor: "fixture", policyIDs: [], evidence: evidence)
                let accepted = try f.commit(origin: local ? f.origin : nil, effects: [delta])
                try f.index.setAuthorityDisposition(
                    id: b.id,
                    evaluation: .init(
                        disposition: .held, reason: "Accepted locally before demotion, never READY."))
                if local { try f.index.retainLocalAuthorityAcceptance(accepted) }
                XCTAssertEqual(try f.index.authorityHasLocalHistoryAdmission(revisionID: b.id), local)
                XCTAssertFalse(try f.index.authorityLocallyExposed(revisionID: b.id))
                XCTAssertNil(try f.index.authorityExposureFloor(itemID: b.target.itemID))
                XCTAssertEqual(
                    try f.index.authorityHistoricalPage(itemID: b.target.itemID).map { $0.descriptor.id },
                    local ? [b.id] : [])
                XCTAssertEqual(try f.index.authorityHistoricalCount(itemID: b.target.itemID), local ? 1 : 0)
                let barrier = ItemState(
                    itemID: b.target.itemID, stateToken: "fixture.accepted-history", status: .reviewRequired,
                    representativeRevisionID: nil, frontier: nil, detailsComplete: false)
                try f.index.replaceCurrentProjection(
                    snapshot: nil, state: barrier, policies: [], policiesComplete: false)
                XCTAssertEqual(try f.index.hasCompleteCurrentProjectionCheckpoint(), local)
            }
        }
    }
    func testLocalVisibilityWorkUsesExactGenerationAndExposureDoesNotRequeue() throws {
        let f = try Fixture()
        try f.transaction {
            let a = try f.item()
            try f.append(a)
            let e = try f.evidence(a)
            let d = AuthorityStore.DispositionDelta(
                target: a.target, eligible: true, actor: "fixture", policyIDs: [],
                evidence: try .init(recordID: e.record.recordID, sha256: e.sha256))
            let c1 = try f.commit(origin: f.origin, effects: [d])
            try f.index.retainLocalAuthorityAcceptance(c1)
            let first = try XCTUnwrap(f.index.authorityLocalVisibilityWorkPage().first)
            let exposure = try f.expose(a, cut: c1.binding)
            XCTAssertEqual(try f.index.authorityLocalVisibilityWorkCount(), 1)
            let r = try f.commit(parents: [c1.binding])
            let negative = AuthorityStore.DispositionDelta(
                target: a.target, eligible: false, actor: "fixture", policyIDs: [], causes: [r.binding])
            let c2 = try f.commit(
                parents: [c1.binding, r.binding], origin: f.origin, localParent: c1.binding,
                effects: [negative])
            try f.index.retainLocalAuthorityAcceptance(c2)
            let newer = try XCTUnwrap(f.index.authorityLocalVisibilityWorkPage().first)
            XCTAssertNotEqual(first.token, newer.token)
            try f.index.clearAuthorityLocalVisibilityWork(itemID: first.itemID, token: first.token)
            XCTAssertEqual(try f.index.authorityLocalVisibilityWorkCount(), 1)
            try f.index.retainLocalAuthorityAcceptance(c1)
            XCTAssertEqual(try f.index.authorityLocalVisibilityWorkPage().first?.token, newer.token)
            try f.index.clearAuthorityLocalVisibilityWork(itemID: newer.itemID, token: newer.token)
            try f.index.retainLocalAuthorityAcceptance(c2)
            try f.index.retainValidatedExposure(exposure, revision: a.original, locallyVisible: true)
            XCTAssertTrue(try f.index.authorityLocalVisibilityWorkPage().isEmpty)
            XCTAssertTrue(try f.index.authorityLocallyExposed(revisionID: a.id))
        }
    }
    func testEquivalentPolicyCoverageUsesValidatedAuthoredContextsAndRealAncestry() throws {
        let f = try Fixture()
        try f.transaction {
            let r = try f.item()
            try f.append(r)
            let a = try f.item(parent: r, subject: "left")
            try f.append(a, parent: r)
            let bp = try RevisionProvenance(
                kind: .authored, originReplicaID: f.id(), parents: [r.id], writtenFields: ["note"],
                unsetFields: [], frontier: [])
            let b = try f.item(parent: r, provenance: bp, changes: ["note": .text("right")])
            try f.append(b, parent: r)
            var limits = RevisionProjection.Limits()
            limits.minimumFreeBytes = UInt64(AttachmentFixtureCapacity.reserveBytes)
            let load: (ItemIndex.CatalogueRow) throws -> PooledCanonicalRecord = {
                try PooledCanonicalRecord.read(row: $0, root: f.root, ownerUID: $0.uid)
            }
            func materialization(_ at: String) throws -> Item {
                let p = try RevisionProvenance(
                    kind: .automaticMerge, originReplicaID: f.id(), parents: [a.id, b.id].sorted(),
                    writtenFields: [], unsetFields: [], frontier: [a.id, b.id].sorted(),
                    mergeProfile: RevisionMerge.profile)
                let m = try f.item(
                    parent: a, subject: "left", at: at, provenance: p, changes: ["note": .text("right")])
                try f.index.setAuthorityDisposition(
                    id: m.id,
                    evaluation: .init(disposition: .eligible, reason: "Validated ordinary auto fixture."))
                _ = try f.index.appendValidatedPeerMaterialization(
                    row: m.row, revision: m.original, loadVerified: load, limits: limits)
                return m
            }
            let m = try materialization("2026-10-14T12:00:00.010Z")
            let n = try materialization("2026-10-14T12:00:00.012Z")
            XCTAssertTrue(
                try f.index.authorityPolicyFrontierCovered(parentID: m.id, physicalFrontier: [m.id, n.id]))
            let e = try f.item(parent: m, subject: "E descends M")
            try f.append(e, parent: m)
            XCTAssertTrue(
                try f.index.authorityPolicyFrontierCovered(parentID: e.id, physicalFrontier: [e.id, n.id]))
            XCTAssertFalse(
                try f.index.authorityPolicyFrontierCovered(parentID: m.id, physicalFrontier: [e.id, n.id]))
            let raw = try f.item(parent: e, subject: "unadmitted")
            XCTAssertFalse(
                try f.index.authorityPolicyFrontierCovered(parentID: e.id, physicalFrontier: [raw.id]))
        }
    }
    func testUnacceptedPendingTimestampCannotCreateExposureFloor() throws {
        let f = try Fixture()
        try f.transaction {
            let pending = try f.item(at: "2099-01-01T00:00:00.000Z")
            let cut = try f.commit()
            code("invalidAuthority") { _ = try f.expose(pending, cut: cut.binding) }
            XCTAssertNil(try f.index.authorityExposureFloor(itemID: pending.target.itemID))
        }
    }
    func testInvalidationHistorySurvivesLaterGrantAndDerivedReplay() throws {
        let f = try Fixture()
        try f.transaction {
            func configuration(_ writer: Bool) -> ItemValue {
                .object([
                    "profile": .text(AccessConfiguration.profile),
                    "users": .list((writer ? ["admin", "fixture"] : ["admin"]).map(ItemValue.text)),
                    "administration": .text("system"),
                ])
            }
            func acceptance(_ item: Item, parents: [AuthorityBinding]) throws
                -> AuthorityStore.VerifiedControlPlan
            {
                let selected = try f.evidence(item)
                let delta = AuthorityStore.DispositionDelta(
                    target: item.target, eligible: true, actor: "fixture", policyIDs: [],
                    evidence: try .init(recordID: selected.record.recordID, sha256: selected.sha256))
                return try f.commit(parents: parents, effects: [delta])
            }
            let initial = try f.item(
                classID: AccessConfiguration.classID,
                changes: ["isDeleted": .boolean(false), "accessConfiguration": configuration(true)])
            let base = try acceptance(initial, parents: [])
            try f.append(initial, control: base.binding)
            let revokeIntent = try RevisionProvenance(
                kind: .authored, originReplicaID: f.origin, parents: [initial.id],
                writtenFields: ["accessConfiguration", "subject"], unsetFields: [], frontier: [])
            let revoked = try f.item(
                parent: initial, subject: "revoked", provenance: revokeIntent,
                changes: ["accessConfiguration": configuration(false)])
            let r = try acceptance(revoked, parents: [base.binding])
            code("invalidAuthorityInventory") {
                try f.index.appendValidatedPeer(
                    row: revoked.row, revision: revoked.original, parent: initial.original,
                    control: base.binding)
            }
            XCTAssertNil(try f.index.revision(revoked.id))
            try f.index.validateRecoveryGraph(requireLinearProjection: false)
            try f.append(revoked, parent: initial, control: r.binding)
            let transition = AuthorityStore.VerifiedInvalidationPlan(
                control: r.binding, sourceCut: base.binding, policy: revoked.original,
                previousPolicyID: initial.id)
            try f.index.retainValidatedInvalidation(transition)
            let grantIntent = try RevisionProvenance(
                kind: .authored, originReplicaID: f.origin, parents: [revoked.id],
                writtenFields: ["accessConfiguration", "subject"], unsetFields: [], frontier: [])
            let granted = try f.item(
                parent: revoked, subject: "granted later", provenance: grantIntent,
                changes: ["accessConfiguration": configuration(true)])
            let g = try acceptance(granted, parents: [r.binding])
            try f.append(granted, parent: revoked, control: g.binding)
            try f.index.retainValidatedInvalidation(
                .init(
                    control: g.binding, sourceCut: r.binding, policy: granted.original,
                    previousPolicyID: revoked.id))
            let transitions = try f.index.authorityInvalidationPage(policyItemID: initial.target.itemID)
            XCTAssertEqual(
                Set(transitions.map { $0.control.recordID }), Set([r.binding.recordID, g.binding.recordID]))
            XCTAssertEqual(
                try f.index.authorityItemFrontierAtCut(itemID: initial.target.itemID, cut: base.binding),
                [initial.id])
            XCTAssertEqual(
                try f.index.authorityItemFrontierAtCut(itemID: initial.target.itemID, cut: g.binding),
                [granted.id])
            try f.index.clearAuthorityControlDerivedState()
            XCTAssertFalse(try f.index.hasValidatedAuthorityControl(r.binding))
            try f.index.retainValidatedControl(base)
            try f.index.retainValidatedControl(r)
            try f.index.retainValidatedControl(g)
            try f.index.retainValidatedInvalidation(transition)
            XCTAssertEqual(try f.index.eligibilityAtCut(revisionID: revoked.id, cut: r.binding), .eligible)
            XCTAssertEqual(
                try f.index.authorityInvalidationPage(policyItemID: initial.target.itemID).first?.control,
                r.binding)
        }
    }
    func testLocalParentCannotBeAnImportedIssuersHead() throws {
        let f = try Fixture()
        try f.transaction {
            let first = try f.commit(origin: f.origin)
            let own = try f.commit(parents: [first.binding], origin: f.origin, localParent: first.binding)
            XCTAssertEqual(try f.index.authorityControlHead(originID: f.origin), own.binding)
            let wrong = try f.commit(parents: [own.binding], admit: false, localParent: own.binding)
            code("invalidAuthority") { try f.index.retainValidatedControl(wrong) }
            XCTAssertEqual(try f.count("authority_control"), 2)
        }
    }
    func testAbsorptionAdvancesOnlyAtExplicitLocalJoinsAndContainsUsesExactCuts() throws {
        let f = try Fixture()
        try f.transaction {
            let remote = try f.id()
            let local = try f.commit(origin: f.origin)
            let r1 = try f.commit(origin: remote)
            let r2 = try f.commit(parents: [r1.binding], origin: remote, localParent: r1.binding)
            XCTAssertFalse(try f.index.authorityControlIsAbsorbed(r2.binding, localCut: local.binding))
            XCTAssertFalse(try f.index.authorityControlContains(r1.binding, in: local.binding))
            let joined = try f.commit(
                parents: [local.binding, r2.binding], origin: f.origin, localParent: local.binding)
            XCTAssertTrue(try f.index.authorityControlIsAbsorbed(r1.binding, localCut: joined.binding))
            XCTAssertTrue(try f.index.authorityControlContains(local.binding, in: joined.binding))
            XCTAssertEqual(try f.count("authority_absorbed"), 4)
            let r3 = try f.commit(parents: [r2.binding], origin: remote, localParent: r2.binding)
            XCTAssertFalse(try f.index.authorityControlIsAbsorbed(r3.binding, localCut: joined.binding))
            let next = try f.commit(
                parents: [joined.binding, r3.binding], origin: f.origin, localParent: joined.binding)
            XCTAssertTrue(try f.index.authorityControlIsAbsorbed(r3.binding, localCut: next.binding))
            XCTAssertEqual(try f.count("authority_absorbed"), 6)
            XCTAssertTrue(try f.index.authorityControlContains(r1.binding, in: next.binding))
            XCTAssertFalse(try f.index.authorityControlContains(next.binding, in: r1.binding))
            XCTAssertEqual(try f.count("authority_control_work"), 0)
        }
    }
    func testMetadataKeysetsUseIndexesAndDeltaPagesPreserveBindings() throws {
        let f = try Fixture()
        try f.transaction {
            let a = try f.item()
            let b = try f.item()
            let cut = try f.commit(changes: [(a, true), (b, false)])
            let first = try f.index.authorityControlDeltaPage(cut.binding, limit: 1)
            let second = try f.index.authorityControlDeltaPage(
                cut.binding, afterRevisionID: first[0].target.revisionID, limit: 1)
            XCTAssertEqual((first + second).map { $0.target.revisionID }, [a.id, b.id].sorted())
            for sql in [
                "SELECT item FROM authority_control_affected WHERE kind='actor' AND value='fixture' ORDER BY item LIMIT 128",
                "SELECT revision FROM authority_local_history WHERE item='fixture' AND retired=1 ORDER BY ticks DESC,revision DESC LIMIT 128",
                "SELECT id FROM authority_control_work WHERE token='fixture' AND processed=0 ORDER BY ordinal DESC,id LIMIT 1",
                "SELECT id FROM authority_control_pending WHERE package='fixture' AND missing=0 ORDER BY id LIMIT 128",
                "SELECT id FROM authority_control_pending WHERE missing=0 ORDER BY id LIMIT 128",
            ] {
                let s = try f.index.corpusPrepare("EXPLAIN QUERY PLAN " + sql)
                defer { sqlite3_finalize(s) }
                var details = ""
                while f.index.catalogueStep(s) == SQLITE_ROW {
                    details += String(cString: sqlite3_column_text(s, 3))
                }
                XCTAssertFalse(details.contains("TEMP B-TREE"), details)
                XCTAssertTrue(details.contains("INDEX"), details)
            }
        }
    }
    func testCausalHistoryExceedsReferenceReducerWindowWithTinyGuardedRecords() throws {
        let f = try Fixture()
        let count = 263
        XCTAssertLessThan(UInt64(count * 8192), Fixture.cap)
        try f.transaction {
            let a = try f.item()
            var head = try f.commit(changes: [(a, true)], origin: f.origin).binding
            for _ in 1..<count {
                head = try f.commit(parents: [head], origin: f.origin, localParent: head).binding
            }
            XCTAssertEqual(try f.count("authority_control"), Int64(count))
            XCTAssertEqual(try f.index.eligibilityAtCut(revisionID: a.id, cut: head), .eligible)
            XCTAssertEqual(try f.count("authority_control_work"), 0)
        }
    }
    func testCutWorkAndNativeCancellationRollbackWithoutDatasetCap() throws {
        let f = try Fixture()
        let a = try f.transaction { try f.item() }
        var cut = try f.transaction { try f.commit(changes: [(a, true)]).binding }
        for _ in 0..<12 { cut = try f.transaction { try f.commit(parents: [cut]).binding } }
        f.index.graphMaximumVMInstructions = 1
        code("resourceLimit") { _ = try f.index.eligibilityAtCut(revisionID: a.id, cut: cut) }
        f.index.graphMaximumVMInstructions = 200_000_000
        var checks = 0
        code("cancelled") {
            try f.transaction {
                try f.index.withCatalogueScanBudget(progress: {
                    checks += 1
                    if checks > 8 { throw TractandaError("cancelled", "Native fixture.") }
                }) {
                    _ = try f.index.eligibilityAtCut(revisionID: a.id, cut: cut)
                }
            }
        }
        XCTAssertGreaterThan(checks, 8)
        XCTAssertEqual(try f.count("authority_control_work"), 0)
        XCTAssertEqual(try f.index.eligibilityAtCut(revisionID: a.id, cut: cut), .eligible)
    }
}
