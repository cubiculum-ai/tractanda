import CSQLite
import CTractandaPlatform
import Crypto
import XCTest

@testable import TractandaCore

final class AuthorityIndexTests: XCTestCase {
    private struct Item {
        let original: AuthorityRevision
        let retained: AuthorityStore.RetainedObject
        let catalogue: ItemIndex.CatalogueRow
    }
    private final class Fixture {
        let root: URL
        let index: ItemIndex
        let origin = try! UUID.makeVersion1().uuidString.lowercased()
        let itemID = try! UUID.makeVersion1().uuidString.lowercased()
        let packageID = try! UUID.makeVersion1().uuidString.lowercased()
        let storeID = try! UUID.makeVersion1().uuidString.lowercased()
        static let cap: UInt64 = 8 * 1024 * 1024
        init() throws {
            try AttachmentFixtureCapacity.requireFree()
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "authority-index-" + Identifier.make())
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            index = try ItemIndex(path: root.appendingPathComponent("index.sqlite").path, create: true)
            index.graphReserveBytes = UInt64(AttachmentFixtureCapacity.reserveBytes)
            try index.validateRecoveryGraph(requireLinearProjection: false)
            try transaction { try index.initializeAuthoritySchema() }
            try capacity()
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
        func capacity(additional: Int = 0) throws {
            try AttachmentFixtureCapacity.requireFree(at: root)
            var total = UInt64(additional)
            guard
                let walk = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: [.fileSizeKey])
            else { throw TractandaError("resourceLimit", "Cannot inspect tiny fixture.") }
            while let url = walk.nextObject() as? URL {
                total += UInt64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            }
            guard total < Self.cap else {
                throw TractandaError("resourceLimit", "Tiny authority fixture cap exceeded.")
            }
        }
        func write(_ bytes: Data, path: String) throws -> FileMetadata {
            try capacity(additional: bytes.count + 4096)
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try bytes.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
            return try FileMetadata.read(at: url)
        }
        func item(
            parent: Item? = nil, subject: String = "root", at: String? = nil, writes: [String]? = nil,
            package: String? = nil, permitted: Bool = true, logicalID: String? = nil,
            changes: [String: ItemValue] = [:]
        ) throws -> Item {
            var fields =
                parent?.original.revision.fields ?? [
                    "classID": .text("Item"), "schemaVersion": .integer(1),
                    "createdAt": .date("2026-10-14T12:00:00.000Z"),
                ]
            let rid = try id()
            fields["itemID"] = .text(parent?.original.revision.itemID ?? logicalID ?? itemID)
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
            if let parent { fields["supersedes"] = .text(parent.original.revision.revisionID) }
            for (key, value) in changes { fields[key] = value }
            fields["revisionAncestry"] = try RevisionProvenance(
                kind: .authored, originReplicaID: origin,
                parents: parent.map { [$0.original.revision.revisionID] } ?? [],
                writtenFields: writes
                    ?? (parent == nil
                        ? fields.keys.filter { !RevisionMerge.managedFields.contains($0) }.sorted()
                        : Array(Set(["subject"]).union(changes.keys)).sorted()),
                unsetFields: [], frontier: []
            ).itemValue
            let value = try Revision(fields: fields, formatVersion: 2)
            let original = try AuthorityRevision(originalBytes: RecordCodec.encode(value))
            let path = "items/2026/10/14/12/00/" + value.itemID + "/" + rid + ".tractanda"
            let metadata = try write(original.originalBytes, path: path)
            return Item(
                original: original,
                retained: .init(
                    descriptor: .init(
                        kind: .item, id: rid, length: original.originalBytes.count, sha256: original.sha256),
                    path: path, packageID: package ?? packageID, peerID: "fixture",
                    configurationDigest: String(repeating: "a", count: 64), permittedOrigin: permitted),
                catalogue: .init(
                    revisionID: rid, itemID: value.itemID, path: path, parentID: value.supersedes,
                    actor: "user:fixture", operationID: fields["operationID"]!.string!, size: metadata.size,
                    inode: metadata.inode, uid: metadata.uid, mode: metadata.mode,
                    modificationSeconds: metadata.modificationSeconds,
                    modificationNanoseconds: metadata.modificationNanoseconds,
                    digest: Data(SHA256.hash(data: original.originalBytes)),
                    createdAt: fields["createdAt"]!.dateString!, modifiedAt: value.modifiedAt,
                    provenance: try value.provenance))
        }
        func retain(_ item: Item, row: AuthorityStore.RetainedObject? = nil) throws {
            try index.retainAuthorityObject(row ?? item.retained, revision: item.original, authority: nil)
        }
        func eligible(_ item: Item) throws {
            try index.setAuthorityDisposition(
                id: item.original.revision.revisionID,
                evaluation: .init(disposition: .eligible, reason: "fresh fixture evaluation"))
        }
        func append(_ item: Item, parent: Item? = nil) throws {
            try retain(item)
            try eligible(item)
            try index.appendValidatedPeer(
                row: item.catalogue, revision: item.original, parent: parent?.original)
        }
        func local(_ item: Item, parent: Item?, expected: String?) throws {
            let value = item.original.revision
            let state = ItemState(
                itemID: value.itemID, stateToken: "fixture." + value.revisionID, status: .ready,
                representativeRevisionID: value.revisionID, frontier: [value.revisionID],
                conflictingFields: [], protectedFields: [], detailsComplete: true)
            try index.appendValidatedLocal(
                row: item.catalogue, revision: value, parent: parent?.original.revision,
                expectedRepresentativeID: expected, state: state,
                policies: [.init(revisionID: value.revisionID, classID: value.classID, permissions: nil)])
        }
        func number(_ sql: String, _ values: [String] = []) throws -> Int64 {
            let s = try index.corpusPrepare(sql, values)
            defer { sqlite3_finalize(s) }
            guard index.catalogueStep(s) == SQLITE_ROW else { throw index.graphSQLiteError() }
            return sqlite3_column_int64(s, 0)
        }
        func evidence(_ item: Item, originID: String? = nil) throws -> AuthorityRecordCodec.Verified {
            let p = try item.original.revision.provenance!
            return try control(
                .authoredEvidence,
                payload: [
                    "sourceControl": .list([]), "target": binding(item),
                    "parents": .list(p.parents.map(ItemValue.text)),
                    "frontier": .list(p.parents.map(ItemValue.text)), "itemPolicies": .list([]),
                    "admissionPolicies": .list([]), "principal": .text("fixture"),
                    "sourceUID": .integer(Int64(tractanda_uid())), "groups": .object([:]),
                    "aliases": .object([:]), "rights": .list([.text("write")]), "evaluated": .boolean(true),
                    "intent": .object([
                        "writtenFields": .list(p.writtenFields.map(ItemValue.text)), "unsetFields": .list([]),
                    ]), "acceptedAuthority": .list([]),
                ], originID: originID)
        }
        func binding(_ item: Item) -> ItemValue {
            .object([
                "itemID": .text(item.original.revision.itemID),
                "revisionID": .text(item.original.revision.revisionID),
                "sha256": .text(item.original.sha256),
            ])
        }
        func control(
            _ kind: AuthorityRecord.Kind, payload: [String: ItemValue], originID: String? = nil
        ) throws
            -> AuthorityRecordCodec.Verified
        {
            try AuthorityRecordCodec.decode(
                AuthorityRecordCodec.encode(
                    AuthorityRecord(
                        recordID: id(), storeID: storeID, originReplicaID: originID ?? origin, kind: kind,
                        actorPrincipal: "fixture", createdAt: "2026-10-14T12:00:00.000Z", payload: payload)))
        }
        func retain(_ control: AuthorityRecordCodec.Verified, permitted: Bool = true) throws {
            let path = "authority/" + control.record.recordID + ".tractanda"
            _ = try write(control.originalBytes, path: path)
            try index.retainAuthorityObject(
                .init(
                    descriptor: .init(
                        kind: .authority, id: control.record.recordID, length: control.originalBytes.count,
                        sha256: control.sha256), path: path, packageID: packageID, peerID: "fixture",
                    configurationDigest: String(repeating: "a", count: 64), permittedOrigin: permitted),
                revision: nil, authority: control)
        }
    }
    private func code(_ expected: String, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body()) { XCTAssertEqual(($0 as? TractandaError)?.code, expected) }
    }

    func testDuplicateRelayRetainsFirstLocatorAndFreshReceiptWithoutResettingAcceptedState() throws {
        let f = try Fixture()
        let item = try f.item(permitted: false)
        try f.transaction { try f.retain(item) }
        XCTAssertEqual(
            try f.index.authorityDisposition(id: item.retained.descriptor.id)?.disposition, .unknownOrigin)
        code("invalidAuthorityInventory") { try f.transaction { try f.eligible(item) } }
        let relay = AuthorityStore.RetainedObject(
            descriptor: item.retained.descriptor, path: "arrival/" + item.retained.descriptor.id,
            packageID: try f.id(), peerID: "relay", configurationDigest: String(repeating: "b", count: 64),
            permittedOrigin: true)
        try f.transaction {
            try f.retain(item, row: relay)
            try f.eligible(item)
            try f.retain(item, row: relay)
        }
        XCTAssertEqual(
            try f.index.retainedAuthorityObject(id: item.retained.descriptor.id)?.path, item.retained.path)
        XCTAssertTrue(
            try XCTUnwrap(f.index.retainedAuthorityObject(id: item.retained.descriptor.id)).permittedOrigin)
        XCTAssertFalse(
            try XCTUnwrap(
                f.index.authorityReceipt(objectID: item.retained.descriptor.id, packageID: f.packageID)
            ).permittedOrigin)
        XCTAssertEqual(try f.number("SELECT COUNT(*) FROM authority_objects"), 1)
        XCTAssertEqual(try f.number("SELECT COUNT(*) FROM authority_packages"), 2)
        let receiptPage = try f.index.authorityObjectReceiptPage(
            objectID: item.retained.descriptor.id, limit: 1)
        let nextReceiptPage = try f.index.authorityObjectReceiptPage(
            objectID: item.retained.descriptor.id, afterPackageID: receiptPage[0].packageID, limit: 1)
        XCTAssertEqual(
            (receiptPage + nextReceiptPage).map { $0.packageID },
            [f.packageID, relay.packageID].sorted())
        XCTAssertEqual(
            try f.index.authorityDisposition(id: item.retained.descriptor.id)?.disposition, .eligible)
        let changed = AuthorityStore.RetainedObject(
            descriptor: item.retained.descriptor, path: item.retained.path, packageID: relay.packageID,
            peerID: "changed", configurationDigest: relay.configurationDigest, permittedOrigin: true)
        code("peerContextChanged") { try f.transaction { try f.retain(item, row: changed) } }
    }
    func testIdentityAndPathCollisionsDoNotReplaceOriginals() throws {
        let f = try Fixture()
        let first = try f.item()
        let second = try f.item()
        try f.transaction { try f.retain(first) }
        let pathCollision = AuthorityStore.RetainedObject(
            descriptor: second.retained.descriptor, path: first.retained.path, packageID: f.packageID,
            peerID: first.retained.peerID, configurationDigest: first.retained.configurationDigest,
            permittedOrigin: true)
        code("invalidAuthorityInventory") { try f.transaction { try f.retain(second, row: pathCollision) } }
        var fields = first.original.revision.fields
        fields["subject"] = .text("different original")
        let changed = try AuthorityRevision(
            originalBytes: RecordCodec.encode(Revision(fields: fields, formatVersion: 2)))
        let descriptor = PeerPackage.Object(
            kind: .item, id: first.retained.descriptor.id, length: changed.originalBytes.count,
            sha256: changed.sha256)
        let collision = AuthorityStore.RetainedObject(
            descriptor: descriptor, path: "arrival/collision", packageID: f.packageID,
            peerID: first.retained.peerID, configurationDigest: first.retained.configurationDigest,
            permittedOrigin: true)
        code("invalidAuthorityInventory") {
            try f.transaction {
                try f.index.retainAuthorityObject(collision, revision: changed, authority: nil)
            }
        }
        XCTAssertEqual(try f.number("SELECT COUNT(*) FROM authority_objects"), 1)
        XCTAssertEqual(
            try Data(contentsOf: f.root.appendingPathComponent(first.retained.path)),
            first.original.originalBytes)
    }
    func testBoundedPagesContinueAfterShortPrefixAndPendingPackageKeysAreIndexed() throws {
        let f = try Fixture()
        var items: [Item] = []
        for _ in 0..<5 { items.append(try f.item()) }
        try f.transaction { for item in items { try f.retain(item) } }
        f.index.graphMaximumPageBytes = 1100
        var cursor: String?
        var ids: [String] = []
        while true {
            let page = try f.index.authorityPackagePage(packageID: f.packageID, after: cursor, limit: 128)
            if page.isEmpty { break }
            XCTAssertLessThan(page.count, 128)
            ids += page.map { $0.descriptor.id }
            cursor = page.last!.descriptor.id
        }
        XCTAssertEqual(ids, items.map { $0.retained.descriptor.id }.sorted())
        XCTAssertEqual(try f.index.retainedAuthorityPage(limit: 128).count, 1)
        let statement = try f.index.corpusPrepare(
            "EXPLAIN QUERY PLAN SELECT DISTINCT package FROM authority_packages INDEXED BY authority_package_pending WHERE pending=1 ORDER BY package LIMIT 128"
        )
        defer { sqlite3_finalize(statement) }
        var details = ""
        while f.index.catalogueStep(statement) == SQLITE_ROW {
            details += String(cString: sqlite3_column_text(statement, 3))
        }
        XCTAssertTrue(details.contains("authority_package_pending"), details)
        XCTAssertFalse(details.contains("TEMP B-TREE"), details)
        f.index.graphMaximumPageBytes = 1
        code("resourceLimit") { _ = try f.index.authorityPackagePage(packageID: f.packageID) }
    }
    func testParentReadinessAndReverseWakeupTouchOnlyAffectedPendingPackages() throws {
        let f = try Fixture()
        let root = try f.item()
        let child = try f.item(parent: root, package: try f.id())
        try f.transaction {
            try f.retain(child)
            try f.index.setAuthorityDisposition(
                id: child.retained.descriptor.id,
                evaluation: .init(disposition: .missingDependencies, reason: "Parent has not arrived."))
        }
        XCTAssertFalse(try f.index.authorityParentsAreEligible(revisionID: child.retained.descriptor.id))
        XCTAssertTrue(try f.index.authorityReadyPage(packageID: child.retained.packageID).isEmpty)
        XCTAssertEqual(
            try f.index.authorityDependentPackagePage(parentID: root.retained.descriptor.id),
            [child.retained.packageID])
        try f.transaction {
            try f.retain(root)
            try f.eligible(root)
        }
        XCTAssertEqual(
            try f.index.authorityReadyPage(packageID: child.retained.packageID).map { $0.descriptor.id },
            [child.retained.descriptor.id])
        try f.transaction {
            try f.index.setAuthorityDisposition(
                id: child.retained.descriptor.id, evaluation: .init(disposition: .held, reason: "review"))
        }
        XCTAssertTrue(
            try f.index.authorityDependentPackagePage(parentID: root.retained.descriptor.id).isEmpty)
        XCTAssertTrue(try f.index.authorityPendingPackagePage().isEmpty)
    }
    func testRetainedInventoryExceedsReferenceNodeWindowWithBoundedPages() throws {
        let f = try Fixture()
        let count = 263
        try f.capacity(additional: count * 4096)
        try f.transaction {
            try f.index.withCatalogueScanBudget {
                for _ in 0..<count {
                    let item = try f.item(logicalID: f.id())
                    try f.retain(item)
                }
            }
        }
        var cursor: String?
        var seen = 0
        while true {
            let page = try f.index.retainedAuthorityPage(after: cursor, limit: 128)
            if page.isEmpty { break }
            seen += page.count
            cursor = page.last!.descriptor.id
        }
        XCTAssertEqual(seen, count)
        XCTAssertEqual(try f.number("SELECT COUNT(*) FROM authority_objects"), Int64(count))
        try f.capacity()
    }
    func testControlDependenciesRetainAllRawEvidenceCandidates() throws {
        let f = try Fixture()
        let root = try f.item()
        let evidence = try f.evidence(root)
        let duplicate = try f.evidence(root)
        let leaf = try f.control(
            .bootstrapPage,
            payload: [
                "manifestID": .text(f.id()),
                "entries": .list([
                    .object([
                        "target": f.binding(root), "frontier": .list([.text(root.retained.descriptor.id)]),
                    ])
                ]),
            ])
        let branch = try f.control(
            .bootstrapIndex,
            payload: [
                "manifestID": leaf.record.payload["manifestID"]!,
                "children": .list([
                    .object(["recordID": .text(leaf.record.recordID), "sha256": .text(leaf.sha256)])
                ]),
            ])
        try f.transaction {
            try f.retain(root)
            try f.retain(evidence)
            try f.retain(leaf)
            try f.retain(branch)
        }
        XCTAssertNil(try f.index.authorityEvidence(revisionID: root.retained.descriptor.id))
        try f.transaction { try f.retain(duplicate) }
        XCTAssertEqual(
            try f.index.authorityEvidenceCandidates(revisionID: root.retained.descriptor.id)
                .map { $0.descriptor.id },
            [evidence.record.recordID, duplicate.record.recordID].sorted())
        XCTAssertEqual(
            try f.number(
                "SELECT COUNT(*) FROM authority_dependencies WHERE source=? AND kind='children' AND target=?",
                [branch.record.recordID, leaf.record.recordID]), 1)
    }
    func testUnknownEvidenceCannotReserveTargetInEitherArrivalOrder() throws {
        for unknownFirst in [true, false] {
            let f = try Fixture()
            let root = try f.item()
            let bad = try f.evidence(root, originID: f.id())
            let good = try f.evidence(root)
            try f.transaction {
                try f.retain(root)
                if unknownFirst { try f.retain(bad, permitted: false) }
                try f.retain(good)
                if !unknownFirst { try f.retain(bad, permitted: false) }
            }
            XCTAssertNil(try f.index.authorityEvidence(revisionID: root.retained.descriptor.id))
            XCTAssertEqual(
                try f.index.authorityEvidenceCandidates(revisionID: root.retained.descriptor.id).count, 2)
            code("invalidAuthorityInventory") {
                try f.transaction {
                    try f.index.setAuthorityDisposition(
                        id: root.retained.descriptor.id,
                        evaluation: .init(
                            disposition: .eligible, reason: "Invalid issuer must not be elected.",
                            evidenceID: bad.record.recordID, evidenceDigest: bad.sha256,
                            evidencePackageID: f.packageID))
                }
            }
            try f.transaction {
                try f.index.setAuthorityDisposition(
                    id: root.retained.descriptor.id,
                    evaluation: .init(
                        disposition: .eligible, reason: "Fresh Store validation.",
                        evidenceID: good.record.recordID, evidenceDigest: good.sha256,
                        evidencePackageID: f.packageID))
            }
            XCTAssertEqual(
                try f.index.authorityEvidence(revisionID: root.retained.descriptor.id)?.descriptor.id,
                good.record.recordID)
        }
    }
    func testAmbiguousOrUnselectedAssessmentClearsSelectedEvidence() throws {
        let f = try Fixture()
        let root = try f.item()
        let first = try f.evidence(root)
        let second = try f.evidence(root)
        func selectFirst() throws {
            try f.index.setAuthorityDisposition(
                id: root.retained.descriptor.id,
                evaluation: .init(
                    disposition: .eligible, reason: "Fresh Store validation.",
                    evidenceID: first.record.recordID, evidenceDigest: first.sha256,
                    evidencePackageID: f.packageID))
        }
        try f.transaction {
            try f.retain(root)
            try f.retain(first)
            try selectFirst()
            try f.retain(second)
        }
        // Raw arrival alone cannot revoke or choose the accepted assessment.
        XCTAssertEqual(
            try f.index.authorityEvidence(revisionID: root.retained.descriptor.id)?.descriptor.id,
            first.record.recordID)
        try f.transaction {
            try f.index.setAuthorityDisposition(
                id: root.retained.descriptor.id,
                evaluation: .init(disposition: .held, reason: "Store found contradictory valid proofs."))
        }
        XCTAssertNil(try f.index.authorityEvidence(revisionID: root.retained.descriptor.id))
        XCTAssertEqual(
            try f.index.authorityEvidenceCandidates(revisionID: root.retained.descriptor.id).count, 2)
        try f.transaction {
            try selectFirst()
            try f.eligible(root)
        }
        XCTAssertNil(try f.index.authorityEvidence(revisionID: root.retained.descriptor.id))
    }
    func testHeldMetadataPreservesAcceptedProofButCanonicalMutationInvalidates() throws {
        let f = try Fixture()
        let item = try f.item()
        let passes = f.index.graphValidationPassesForTesting
        try f.transaction {
            try f.retain(item)
            try f.index.setAuthorityDisposition(
                id: item.retained.descriptor.id,
                evaluation: .init(disposition: .held, reason: "pending review"))
        }
        XCTAssertTrue(try f.index.acceptedGraphProofIsCurrent())
        XCTAssertEqual(f.index.graphValidationPassesForTesting, passes)
        try f.index.execute("UPDATE revision_catalog SET actor=actor")
        XCTAssertFalse(try f.index.acceptedGraphProofIsCurrent())
    }
    func testWalkResumeAggregateStagingAndCallerRollback() throws {
        let f = try Fixture()
        let a = try f.id()
        let b = try f.id()
        try f.transaction {
            try f.index.authorityBeginWalk(token: "outer")
            XCTAssertTrue(try f.index.authorityVisitOnce(token: "outer", id: a))
            XCTAssertFalse(try f.index.authorityVisitOnce(token: "outer", id: a))
            try f.index.authorityBeginWalk(token: "inner")
            XCTAssertTrue(try f.index.authorityVisitOnce(token: "inner", id: a))
            let old = f.index.graphMaximumTemporaryBytes
            f.index.graphMaximumTemporaryBytes = UInt64(
                try f.number("SELECT cost FROM authority_walk WHERE token='' AND object=''"))
            code("resourceLimit") { _ = try f.index.authorityVisitOnce(token: "outer", id: b) }
            f.index.graphMaximumTemporaryBytes = old
            try f.index.authorityEndWalk(token: "inner")
            try f.index.authorityBeginWalk(token: "outer")
            XCTAssertTrue(try f.index.authorityVisitOnce(token: "outer", id: a))
            try f.index.authorityEndWalk(token: "outer")
        }
        XCTAssertEqual(try f.number("SELECT COUNT(*) FROM authority_walk"), 1)
        XCTAssertEqual(try f.number("SELECT cost FROM authority_walk WHERE token='' AND object=''"), 0)
    }
    func testVMAndCancellationCallbacksBoundMetadataWork() throws {
        let f = try Fixture()
        f.index.graphMaximumVMInstructions = 1
        code("resourceLimit") { _ = try f.index.retainedAuthorityPage() }
        f.index.graphMaximumVMInstructions = 200_000_000
        var checks = 0
        code("cancelled") {
            try f.transaction {
                try f.index.withCatalogueScanBudget(progress: {
                    checks += 1
                    if checks > 8 { throw TractandaError("cancelled", "fixture") }
                }) {
                    try f.index.authorityBeginWalk(token: "cancel")
                    for _ in 0..<100 { _ = try f.index.authorityVisitOnce(token: "cancel", id: f.id()) }
                }
            }
        }
        XCTAssertGreaterThan(checks, 8)
        XCTAssertGreaterThan(f.index.lastCatalogueScanWorkForTesting, 0)
        XCTAssertEqual(try f.number("SELECT COUNT(*) FROM authority_walk"), 1)
    }
    func testPeerAppendExtendsOlderAcceptedParentWithoutRescanOrClockRewrite() throws {
        let f = try Fixture()
        let root = try f.item(changes: ["isDeleted": .boolean(false)])
        let first = try f.item(parent: root, subject: "first", at: "2026-10-14T12:10:00.000Z")
        let later = try f.item(parent: root, subject: "fork", at: "2026-10-14T12:01:00.0000001Z")
        let passes = f.index.graphValidationPassesForTesting
        try f.transaction {
            try f.append(root)
            try f.append(first, parent: root)
            try f.append(later, parent: root)
        }
        XCTAssertTrue(try f.index.acceptedGraphProofIsCurrent())
        XCTAssertEqual(f.index.graphValidationPassesForTesting, passes)
        XCTAssertEqual(try f.number("SELECT COUNT(*) FROM revision_catalog"), 3)
        XCTAssertEqual(try f.number("SELECT COUNT(*) FROM recovery_forks"), 1)
        XCTAssertNil(try f.index.recoveryHead())
        XCTAssertEqual(
            try f.index.revision(later.catalogue.revisionID)?.modifiedAt, later.original.revision.modifiedAt)
        try f.transaction {
            try f.index.appendValidatedPeer(
                row: later.catalogue, revision: later.original, parent: root.original)
        }
        XCTAssertEqual(try f.number("SELECT COUNT(*) FROM revision_catalog"), 3)
        try f.capacity()
    }
    func testPeerAppendRejectsMalformedDeltaAndStaleProofWithoutAcceptedMutation() throws {
        let f = try Fixture()
        let root = try f.item()
        try f.transaction { try f.append(root) }
        let bad = try f.item(parent: root, subject: "undeclared", writes: [])
        try f.transaction {
            try f.retain(bad)
            try f.eligible(bad)
        }
        code("invalidAuthorityInventory") {
            try f.transaction {
                try f.index.appendValidatedPeer(
                    row: bad.catalogue, revision: bad.original, parent: root.original)
            }
        }
        XCTAssertEqual(try f.number("SELECT COUNT(*) FROM revision_catalog"), 1)
        XCTAssertFalse(try f.index.acceptedGraphProofIsCurrent())
        code("projectionRequired") {
            try f.transaction {
                try f.index.appendValidatedPeer(
                    row: bad.catalogue, revision: bad.original, parent: root.original)
            }
        }
    }
    func testPeerAppendRejectsProtectedLifecycleChange() throws {
        let f = try Fixture()
        let root = try f.item()
        try f.transaction { try f.append(root) }
        let deleted = try f.item(parent: root, changes: ["isDeleted": .boolean(true)])
        try f.transaction {
            try f.retain(deleted)
            try f.eligible(deleted)
        }
        code("invalidAuthorityInventory") {
            try f.transaction {
                try f.index.appendValidatedPeer(
                    row: deleted.catalogue, revision: deleted.original, parent: root.original)
            }
        }
        XCTAssertEqual(try f.number("SELECT COUNT(*) FROM revision_catalog"), 1)
    }
    func testSharedBookkeepingPreservesLocalNormalAppendAndStaleCASRejection() throws {
        let f = try Fixture()
        let root = try f.item()
        let child = try f.item(parent: root, subject: "local")
        try f.transaction {
            try f.local(root, parent: nil, expected: nil)
            try f.local(child, parent: root, expected: root.catalogue.revisionID)
        }
        XCTAssertEqual(
            try f.index.currentProjection(itemID: f.itemID)?.state.representativeRevisionID,
            child.catalogue.revisionID)
        let stale = try f.item(parent: root, subject: "stale")
        code("revisionConflict") {
            try f.transaction { try f.local(stale, parent: root, expected: root.catalogue.revisionID) }
        }
        XCTAssertEqual(try f.number("SELECT COUNT(*) FROM revision_catalog"), 2)
    }
    func testPeerAppendWorkGuardAndExistingLocalCASRemainEnforced() throws {
        let f = try Fixture()
        let root = try f.item()
        let state = ItemState(
            itemID: f.itemID, stateToken: "fixture", status: .ready,
            representativeRevisionID: root.catalogue.revisionID, frontier: [root.catalogue.revisionID],
            conflictingFields: [], protectedFields: [], detailsComplete: true)
        try f.transaction {
            try f.retain(root)
            try f.eligible(root)
            try f.index.appendValidatedLocal(
                row: root.catalogue, revision: root.original.revision, parent: nil,
                expectedRepresentativeID: nil, state: state,
                policies: [.init(revisionID: root.catalogue.revisionID, classID: "Item", permissions: nil)])
        }
        let child = try f.item(parent: root, subject: "work guarded")
        try f.transaction {
            try f.retain(child)
            try f.eligible(child)
        }
        f.index.graphMaximumVMInstructions = 1
        code("resourceLimit") {
            try f.transaction {
                try f.index.appendValidatedPeer(
                    row: child.catalogue, revision: child.original, parent: root.original)
            }
        }
        f.index.graphMaximumVMInstructions = 200_000_000
        XCTAssertEqual(try f.number("SELECT COUNT(*) FROM revision_catalog"), 1)
        XCTAssertFalse(try f.index.acceptedGraphProofIsCurrent())
    }
}
