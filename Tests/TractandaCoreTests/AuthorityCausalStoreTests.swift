import CTractandaPlatform
import Foundation
import XCTest

@testable import TractandaCore

final class AuthorityCausalStoreTests: XCTestCase {
    private func code(
        _ expected: String, _ body: () throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(($0 as? TractandaError)?.code, expected, file: file, line: line)
        }
    }
    private func receiverEdit(_ f: PeerIntakeStoreTests.Fixture, subject: String = "offline Bob") throws
        -> Revision
    {
        try f.receiver.withAccess(forUID: f.receiverAccounts.bob) {
            let parent = try f.receiver.get(f.base.itemID)
            return try f.receiver.commit(
                .init(
                    action: .revise, itemID: parent.itemID,
                    expectedRevisionID: parent.revisionID, changes: ["subject": .text(subject)],
                    operationID: "bob-" + (try PeerIntakeStoreTests.Fixture.id()))
            ).revision
        }
    }
    private func revoke(_ f: PeerIntakeStoreTests.Fixture) throws -> Revision {
        try f.source.configureAccess(
            .object([
                "profile": .text(AccessConfiguration.profile),
                "users": .list([.text("admin"), .text("alice")]),
            ]), operationID: "revoke-" + (try PeerIntakeStoreTests.Fixture.id())
        ).revision
    }
    private func configureBoth(_ f: PeerIntakeStoreTests.Fixture) throws -> PeerPackage.Context {
        let origins = [try XCTUnwrap(f.source.replicaID), try XCTUnwrap(f.receiver.replicaID)].sorted()
        let previous = f.context!
        f.context = try PeerPackage.Context(
            peerID: "raven-both", storeID: f.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("raven-both".utf8)),
            permittedOrigins: origins)
        let stash = try PeerPackage.Context(
            peerID: "stash", storeID: f.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("stash-both".utf8)),
            permittedOrigins: origins)
        try f.receiver.configurePeerIntake(peers: [previous, f.context])
        try f.source.configurePeerIntake(peers: [stash])
        return stash
    }
    private func response(_ store: ItemStore, _ method: String, _ args: [String: Any]) throws -> [String: Any]
    {
        let request = try JSONSerialization.data(withJSONObject: [
            "using": [ItemService.capability],
            "methodCalls": [[method, args, "c"]],
        ])
        let reply = try ItemService(store: store).handle(request, peerUID: tractanda_uid())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
        let calls = try XCTUnwrap(object["methodResponses"] as? [[Any]])
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call[0] as? String, method, "Unexpected API error: \(call)")
        return try XCTUnwrap(call[1] as? [String: Any])
    }
    func testUnseenOfflineWriteIsDemotedWithNewChangedViewRevisionAndExactReadableHistory() throws {
        let f = try PeerIntakeStoreTests.Fixture()
        try f.bootstrap()
        f.receiver.publicationClockForTesting = { "2090-01-01T00:00:00Z" }
        let b = try receiverEdit(f)
        let original = try XCTUnwrap(f.receiver.peerMetadataObjects(revisionID: b.revisionID).first).1
        let r = try revoke(f)
        let result = try f.send(f.packet(f.source.peerMetadataObjects(revisionID: r.revisionID)))
        if result.accepted != 1 {
            let diagnostic = try ItemIndex(
                path: f.receiverRoot.appendingPathComponent("index/items.sqlite").path, create: false)
            defer { diagnostic.close() }
            let status = try diagnostic.authorityDisposition(id: r.revisionID)
            let coordinator = PeerIntakeCoordinator(
                root: f.receiverRoot, ownerUID: tractanda_uid(), storeID: f.storeID)
            let exported = try f.source.peerMetadataObjects(revisionID: r.revisionID)
            let raw = try XCTUnwrap(
                exported.first { PeerIntakeStoreTests.Fixture.isEvidence($0, for: r.revisionID) })
            let evidence = try AuthorityRecordCodec.decode(raw.1).record
            try coordinator.validatePolicyCut(evidence, index: diagnostic)
            let cut = try XCTUnwrap(coordinator.sourceControl(evidence))
            let current = try f.receiver.get(f.configuration.itemID)
            let outcome = try RuntimeAuthorityEvaluator(
                accounts: f.receiverAccounts,
                currentConfigurations: [AccessConfiguration(current.fields["accessConfiguration"]!)],
                currentItemPolicies: [current], ownerUID: tractanda_uid(),
                loadBinding: { try coordinator.bindingAtCut($0, cut: cut, index: diagnostic) }
            )
            .evaluate(
                AuthorityRevision(originalBytes: RecordCodec.encode(r)), evidence: evidence, allowPolicy: true
            )
            throw TractandaError(
                "policyNotAdmitted",
                "\(status?.disposition.rawValue ?? "none"): \(status?.reason ?? "none"); evaluator=\(outcome.reason)"
            )
        }
        let d = try f.receiver.withAccess(forUID: f.receiverAccounts.alice) { try f.receiver.get(b.itemID) }
        XCTAssertNotEqual(d.revisionID, b.revisionID)
        XCTAssertEqual(d.fields["subject"], f.base.fields["subject"])
        XCTAssertEqual(try d.provenance?.mergeProfile, AuthorityStore.reconciliationProfile)
        XCTAssertEqual(try d.provenance?.parents, [f.base.revisionID])
        XCTAssertEqual(try d.provenance?.writtenFields, [])
        XCTAssertGreaterThan(try RevisionTimestamp(d.modifiedAt), try RevisionTimestamp(b.modifiedAt))
        let exact = try f.receiver.withAccess(forUID: f.receiverAccounts.alice) {
            try f.receiver.get(b.itemID, revisionID: b.revisionID)
        }
        XCTAssertEqual(exact, b)
        XCTAssertEqual(try RecordCodec.encode(exact), original)
        XCTAssertEqual(try f.receiver.historicalDispositions(for: [exact]), [b.revisionID: .demoted])
        code("forbidden") {
            _ = try f.receiver.withAccess(forUID: f.receiverAccounts.bob) {
                try f.receiver.get(b.itemID, revisionID: b.revisionID)
            }
        }
        let changed = try Categories.query(
            store: f.receiver,
            expression: "itemID == \"\(b.itemID)\" && modifiedAt > $time.iso(\"\(b.modifiedAt)\")")
        XCTAssertEqual(changed.map(\.revisionID), [d.revisionID])
        let request = try JSONSerialization.data(withJSONObject: [
            "using": [ItemService.capability],
            "methodCalls": [
                ["TractandaItem/history", ["itemID": b.itemID, "position": 0, "limit": 20], "h"]
            ],
        ])
        XCTAssertNil(
            try ItemService(store: f.receiver).preparePooledHistory(
                nativeFixtureInvocation(request), peerUID: tractanda_uid()))
        let history = try response(
            f.receiver, "TractandaItem/history",
            ["itemID": b.itemID, "position": 0, "limit": 20])
        XCTAssertEqual((history["historicalDispositions"] as? [String: String])?[b.revisionID], "demoted")
        let exactResponse = try response(
            f.receiver, "TractandaRevision/get",
            ["itemID": b.itemID, "revisionID": b.revisionID])
        XCTAssertEqual(
            (exactResponse["historicalDispositions"] as? [String: String])?[b.revisionID], "demoted")
        try f.receiver.rebuildIndex()
        XCTAssertEqual(try f.receiver.get(b.itemID).revisionID, d.revisionID)
        f.receiver = nil
        f.receiver = try PeerIntakeStoreTests.Fixture.open(f.receiverRoot, f.receiverAccounts)
        XCTAssertEqual(try f.receiver.get(b.itemID).revisionID, d.revisionID)
        _ = try f.send(f.packet(f.source.peerMetadataObjects(revisionID: r.revisionID)))
        XCTAssertEqual(try f.receiver.get(b.itemID).revisionID, d.revisionID)
        try f.capacity()
    }
    func testRevocationPreservesOriginalAlreadyAcceptedAtItsFrozenSourceCut() throws {
        let f = try PeerIntakeStoreTests.Fixture()
        try f.bootstrap()
        let stash = try configureBoth(f)
        let b = try receiverEdit(f)
        _ = try f.send(
            f.packet(f.receiver.peerMetadataObjects(revisionID: b.revisionID)), context: stash, to: f.source)
        let r = try revoke(f)
        _ = try f.send(f.packet(f.source.peerMetadataObjects(revisionID: r.revisionID)))
        XCTAssertEqual(try f.receiver.get(b.itemID).revisionID, b.revisionID)
        XCTAssertTrue(try f.receiver.historicalDispositions(for: [b]).isEmpty)
        code("forbidden") {
            _ = try f.receiver.withAccess(forUID: f.receiverAccounts.bob) { try f.receiver.get(b.itemID) }
        }
        try f.receiver.rebuildIndex()
        XCTAssertEqual(try f.receiver.get(b.itemID).revisionID, b.revisionID)
        try f.capacity()
    }
    func testSealedAcceptanceRecoversBeforeAssessmentAndKeepsItsExactEvidence() throws {
        let f = try PeerIntakeStoreTests.Fixture()
        try f.bootstrap()
        let b = try f.edit(uid: f.sourceAccounts.bob)
        let objects = try f.source.peerMetadataObjects(revisionID: b.revisionID)
        var hit = false
        f.receiver.authorityAfterAcceptanceSealForTesting = {
            hit = true
            throw TractandaError("injectedCrash", "After acceptance control seal, before private assessment")
        }
        code("injectedCrash") { _ = try f.send(f.packet(objects)) }
        XCTAssertTrue(hit)
        f.receiver = nil
        f.receiver = try PeerIntakeStoreTests.Fixture.open(f.receiverRoot, f.receiverAccounts)
        XCTAssertEqual(try f.receiver.get(b.itemID), b)
        let selected = try XCTUnwrap(
            objects.first { pair in
                PeerIntakeStoreTests.Fixture.isEvidence(pair, for: b.revisionID)
            })
        let witness = try AuthorityRecordCodec.decode(selected.1).record
        var fields = witness.payload
        fields["groups"] = .object([:])
        let contradictory = try AuthorityRecord(
            recordID: PeerIntakeStoreTests.Fixture.id(),
            storeID: witness.storeID, originReplicaID: witness.originReplicaID, kind: .authoredEvidence,
            parentAuthorityIDs: witness.parentAuthorityIDs, actorPrincipal: witness.actorPrincipal,
            createdAt: Timestamp.now(), payload: fields)
        let bytes = try AuthorityRecordCodec.encode(contradictory)
        _ = try f.send(
            f.packet([
                (
                    .init(
                        kind: .authority, id: contradictory.recordID,
                        length: bytes.count, sha256: AuthorityRecordCodec.sha256(bytes)), bytes
                )
            ]))
        try f.receiver.rebuildIndex()
        XCTAssertEqual(try f.receiver.get(b.itemID), b)
        let exported = try f.receiver.peerMetadataObjects(revisionID: b.revisionID)
        XCTAssertEqual(
            exported.first { pair in
                PeerIntakeStoreTests.Fixture.isEvidence(pair, for: b.revisionID)
            }?.0.id, selected.0.id)
        try f.capacity()
    }
    func testLaterGrantDoesNotApproveOldIntentInEitherDependencyArrivalOrder() throws {
        for grantFirst in [false, true] {
            let f = try PeerIntakeStoreTests.Fixture()
            try f.bootstrap()
            f.receiver.publicationClockForTesting = { "2090-01-02T00:00:00Z" }
            let b = try receiverEdit(f)
            let r = try revoke(f)
            let rPacket = try f.packet(f.source.peerMetadataObjects(revisionID: r.revisionID))
            let grant = try f.source.configureAccess(
                .object([
                    "profile": .text(AccessConfiguration.profile),
                    "users": .list([.text("admin"), .text("alice"), .text("bob")]),
                ]), operationID: "grant"
            ).revision
            let grantPacket = try f.packet(f.source.peerMetadataObjects(revisionID: grant.revisionID))
            if grantFirst {
                XCTAssertEqual(try f.send(grantPacket).missing, 1)
                XCTAssertEqual(
                    try f.receiver.get(b.itemID).revisionID, b.revisionID,
                    "Pending proof is not a review hold or a grant.")
            }
            _ = try f.send(rPacket)
            _ = try f.send(grantPacket)
            let current = try f.receiver.get(b.itemID)
            XCTAssertEqual(current.fields["subject"], f.base.fields["subject"])
            XCTAssertNotEqual(current.revisionID, b.revisionID)
            XCTAssertEqual(try f.receiver.historicalDispositions(for: [b]), [b.revisionID: .demoted])
            XCTAssertEqual(
                try f.receiver.get(f.configuration.itemID, revisionID: f.configuration.revisionID),
                f.configuration,
                "A retained old policy does not authorize stale intent.")
            let fresh = try receiverEdit(f, subject: "fresh after grant")
            XCTAssertEqual(try f.receiver.get(b.itemID), fresh)
            XCTAssertEqual(fresh.supersedes, current.revisionID)
            try f.receiver.rebuildIndex()
            XCTAssertEqual(try f.receiver.get(b.itemID), fresh)
            XCTAssertEqual(try f.receiver.historicalDispositions(for: [b]), [b.revisionID: .demoted])
            try f.capacity()
        }
    }
    func testEquivalentEffectivePolicyAndWarmReopenDoNotMintReconciliationOrControls() throws {
        let f = try PeerIntakeStoreTests.Fixture()
        try f.bootstrap()
        let b = try receiverEdit(f)
        let policy = try f.source.configureAccess(
            .object([
                "profile": .text(AccessConfiguration.profile),
                "users": .list([.text("bob"), .text("alice"), .text("admin")]),
            ]), operationID: "same-effective-policy"
        ).revision
        _ = try f.send(f.packet(f.source.peerMetadataObjects(revisionID: policy.revisionID)))
        XCTAssertEqual(try f.receiver.get(b.itemID).revisionID, b.revisionID)
        func authorityCount() throws -> Int {
            var count = 0
            let iterator = FileManager.default.enumerator(
                at: f.receiverRoot.appendingPathComponent("authority/records"),
                includingPropertiesForKeys: nil)!
            while let path = iterator.nextObject() as? URL {
                if path.pathExtension == "authority" { count += 1 }
            }
            return count
        }
        let before = try authorityCount()
        f.receiver = nil
        f.receiver = try PeerIntakeStoreTests.Fixture.open(f.receiverRoot, f.receiverAccounts)
        XCTAssertEqual(try f.receiver.get(b.itemID).revisionID, b.revisionID)
        XCTAssertEqual(
            try authorityCount(), before, "An empty warm visibility queue emits no controls or witnesses.")
        try f.capacity()
    }

    func testDemotedCreationHasNoOldPolicyGrantAndHistoryIsAdministratorOnly() throws {
        let f = try PeerIntakeStoreTests.Fixture()
        try f.bootstrap()
        let born = try f.receiver.withAccess(forUID: f.receiverAccounts.bob) {
            try f.receiver.commit(
                .init(
                    classID: "Item", changes: ["subject": .text("Bob root")],
                    operationID: "new-bob-root")
            ).revision
        }
        let r = try revoke(f)
        _ = try f.send(f.packet(f.source.peerMetadataObjects(revisionID: r.revisionID)))
        let state = try f.receiver.itemState(born.itemID)
        XCTAssertEqual(state.status, .reviewRequired)
        XCTAssertNil(state.representativeRevisionID)
        XCTAssertEqual(try f.receiver.get(born.itemID, revisionID: born.revisionID), born)
        XCTAssertEqual(try f.receiver.historicalDispositions(for: [born]), [born.revisionID: .demoted])
        code("forbidden") {
            _ = try f.receiver.withAccess(forUID: f.receiverAccounts.alice) {
                try f.receiver.get(born.itemID, revisionID: born.revisionID)
            }
        }
        try f.receiver.rebuildIndex()
        f.receiver = nil
        f.receiver = try PeerIntakeStoreTests.Fixture.open(f.receiverRoot, f.receiverAccounts)
        XCTAssertEqual(try f.receiver.itemState(born.itemID).status, .reviewRequired)
        XCTAssertEqual(try f.receiver.get(born.itemID, revisionID: born.revisionID), born)
        XCTAssertEqual(try f.receiver.historicalDispositions(for: [born]), [born.revisionID: .demoted])
        code("forbidden") {
            _ = try f.receiver.withAccess(forUID: f.receiverAccounts.alice) {
                try f.receiver.get(born.itemID, revisionID: born.revisionID)
            }
        }
        try f.capacity()
    }

    func testEquivalentMaterializationExchangeThenRealChildKeepsValidCutAndQuiesces() throws {
        let f = try PeerIntakeStoreTests.Fixture()
        try f.bootstrap()
        let stash = try configureBoth(f)
        let a = try f.edit(subject: "source subject")
        let b = try f.receiver.withAccess(forUID: f.receiverAccounts.alice) {
            try f.receiver.commit(
                .init(
                    action: .revise, itemID: f.base.itemID,
                    expectedRevisionID: f.base.revisionID, changes: ["body": .text("receiver body")],
                    operationID: "receiver-body")
            ).revision
        }
        _ = try f.send(f.packet(f.source.peerMetadataObjects(revisionID: a.revisionID)))
        _ = try f.send(
            f.packet(f.receiver.peerMetadataObjects(revisionID: b.revisionID)), context: stash, to: f.source)
        let m = try f.source.get(f.base.itemID)
        let n = try f.receiver.get(f.base.itemID)
        XCTAssertEqual(try m.provenance?.frontier, try n.provenance?.frontier)
        XCTAssertNotEqual(m.revisionID, n.revisionID)
        func localControls(_ root: URL, _ origin: String) throws -> Set<String> {
            var result: Set<String> = []
            let iterator = FileManager.default.enumerator(
                at: root.appendingPathComponent("authority/records"),
                includingPropertiesForKeys: nil)!
            while let path = iterator.nextObject() as? URL {
                guard path.pathExtension == "authority" else { continue }
                let record = try AuthorityRecordCodec.decode(Data(contentsOf: path)).record
                if record.kind == .controlCommit && record.originReplicaID == origin {
                    result.insert(record.recordID)
                }
            }
            return result
        }
        let sourceOrigin = try XCTUnwrap(f.source.replicaID)
        let receiverOrigin = try XCTUnwrap(f.receiver.replicaID)
        let sourceControls = try localControls(f.sourceRoot, sourceOrigin)
        let receiverControls = try localControls(f.receiverRoot, receiverOrigin)
        _ = try f.send(
            f.packet(f.receiver.peerMetadataObjects(revisionID: n.revisionID)), context: stash, to: f.source)
        _ = try f.send(f.packet(f.source.peerMetadataObjects(revisionID: m.revisionID)))
        XCTAssertEqual(try localControls(f.sourceRoot, sourceOrigin), sourceControls)
        XCTAssertEqual(try localControls(f.receiverRoot, receiverOrigin), receiverControls)
        let winner = try f.receiver.get(f.base.itemID)
        XCTAssertEqual(winner.revisionID, try f.source.get(f.base.itemID).revisionID)
        let child = try f.receiver.withAccess(forUID: f.receiverAccounts.alice) {
            try f.receiver.commit(
                .init(
                    action: .revise, itemID: winner.itemID,
                    expectedRevisionID: winner.revisionID, changes: ["subject": .text("real child")],
                    operationID: "child-of-winning-materialization")
            ).revision
        }
        XCTAssertEqual(child.supersedes, winner.revisionID)
        let childPacket = try f.packet(f.receiver.peerMetadataObjects(revisionID: child.revisionID))
        XCTAssertEqual(try f.send(childPacket, context: stash, to: f.source).accepted, 1)
        XCTAssertEqual(try f.source.get(child.itemID), child)
        _ = try f.send(
            f.packet(f.receiver.peerMetadataObjects(revisionID: n.revisionID)), context: stash, to: f.source)
        XCTAssertEqual(
            try f.source.get(child.itemID), child, "Obsolete equivalent N cannot displace authored E.")
        f.receiver = nil
        f.source = nil
        f.receiver = try PeerIntakeStoreTests.Fixture.open(f.receiverRoot, f.receiverAccounts)
        f.source = try PeerIntakeStoreTests.Fixture.open(f.sourceRoot, f.sourceAccounts)
        XCTAssertEqual(try f.receiver.get(child.itemID), child)
        XCTAssertEqual(try f.source.get(child.itemID), child)
        let before = try localControls(f.sourceRoot, sourceOrigin)
        _ = try f.send(childPacket, context: stash, to: f.source)
        XCTAssertEqual(try localControls(f.sourceRoot, sourceOrigin), before)
        try f.capacity()
    }

    func testInterruptedDemotionCompletesClockReconciliationBeforeServingAndReplaysOnce() throws {
        for phase in ["prepared", "sealed", "original", "applied"] {
            let f = try PeerIntakeStoreTests.Fixture()
            try f.bootstrap()
            f.receiver.publicationClockForTesting = { "2090-02-01T00:00:00Z" }
            let b = try receiverEdit(f)
            let r = try revoke(f)
            let packet = try f.packet(f.source.peerMetadataObjects(revisionID: r.revisionID))
            var prepared = 0
            var armed = false
            var hit = false
            f.receiver.peerIntakeBoundaryForTesting = { boundary in
                if boundary == .prepared { prepared += 1 }
                if prepared == 3 { armed = true }
                if armed && boundary.rawValue == phase {
                    hit = true
                    throw TractandaError("injectedCrash", "Demotion boundary " + phase)
                }
            }
            f.receiver.peerIntakeOriginalPublicationForTesting = {
                if armed && phase == "original" {
                    hit = true
                    throw TractandaError("injectedCrash", "Demotion original publication")
                }
            }
            code("injectedCrash") { _ = try f.send(packet) }
            XCTAssertTrue(hit, "Boundary did not execute: " + phase)
            XCTAssertTrue(StoreCheckpoint.isDirty(root: f.receiverRoot))
            let identityDirectory = f.receiverRoot.appendingPathComponent(
                "authority/local-reconciliation-identities")
            let identities = try FileManager.default.contentsOfDirectory(
                at: identityDirectory,
                includingPropertiesForKeys: nil)
            let identity = try XCTUnwrap(identities.first)
            let reserved = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: identity)) as? [String: Any])
            let reservedID = try XCTUnwrap(reserved["outputRevisionID"] as? String)
            f.receiver = nil
            f.receiver = try PeerIntakeStoreTests.Fixture.open(f.receiverRoot, f.receiverAccounts)
            let current = try f.receiver.get(b.itemID)
            XCTAssertEqual(current.revisionID, reservedID, "Prepared publication identity survives restart.")
            XCTAssertEqual(try current.provenance?.mergeProfile, AuthorityStore.reconciliationProfile)
            XCTAssertEqual(current.fields["subject"], f.base.fields["subject"])
            XCTAssertGreaterThan(
                try RevisionTimestamp(current.modifiedAt), try RevisionTimestamp(b.modifiedAt))
            XCTAssertEqual(try f.receiver.historicalDispositions(for: [b]), [b.revisionID: .demoted])
            try f.receiver.rebuildIndex()
            XCTAssertEqual(try f.receiver.get(b.itemID).revisionID, current.revisionID)
            _ = try f.send(packet)
            XCTAssertEqual(try f.receiver.get(b.itemID).revisionID, current.revisionID)
            let originals = try f.receiver.exportCatalogueForVerification().filter { $0.itemID == b.itemID }
            XCTAssertEqual(
                originals.filter { $0.provenance?.mergeProfile == AuthorityStore.reconciliationProfile }
                    .count, 1)
            try f.capacity()
        }
    }

    func testThreePeersImportKnownHeldNegativeAndContinueWithValidDescendant() throws {
        let f = try PeerIntakeStoreTests.Fixture()
        try f.bootstrap()
        // Three small stores are estimated at24MiB before allocating the third root.
        XCTAssertLessThanOrEqual(24 * 1024 * 1024, Int(AttachmentFixtureCapacity.fixtureCapBytes))
        try AttachmentFixtureCapacity.requireFree(at: f.directory)
        let root = f.directory.appendingPathComponent("starlet")
        let accounts = PeerIntakeStoreTests.Accounts()
        var p: ItemStore! = try f.openFreshSharedReplica(root, accounts)
        defer { p = nil }
        let origins = [f.origin, try XCTUnwrap(f.receiver.replicaID), try XCTUnwrap(p.replicaID)].sorted()
        func context(_ peer: String) throws -> PeerPackage.Context {
            try .init(
                peerID: peer, storeID: f.storeID,
                configurationDigest: AuthorityRecordCodec.sha256(Data((peer + "-three").utf8)),
                permittedOrigins: origins)
        }
        let previous = f.context!
        f.context = try context("raven-three")
        let stash = try context("stash")
        let starlet = try context("starlet")
        try f.receiver.configurePeerIntake(peers: [previous, f.context, starlet])
        try p.configurePeerIntake(peers: [f.context, stash])
        try f.bootstrap(to: p)
        f.receiver.publicationClockForTesting = { "2090-03-01T00:00:00Z" }
        let b = try receiverEdit(f)
        XCTAssertEqual(
            try f.send(
                f.packet(f.receiver.peerMetadataObjects(revisionID: b.revisionID)),
                context: stash, to: p
            ).accepted, 1)
        XCTAssertEqual(try p.get(b.itemID), b)
        let r = try revoke(f)  // Raven never accepted B in R's PRE cut.
        let rPacket = try f.packet(f.source.peerMetadataObjects(revisionID: r.revisionID))
        _ = try f.send(rPacket)
        _ = try f.send(rPacket, context: f.context, to: p)
        let d = try p.get(b.itemID)
        XCTAssertNotEqual(d.revisionID, b.revisionID)
        XCTAssertEqual(try f.receiver.historicalDispositions(for: [b]), [b.revisionID: .demoted])
        let negativePacket = try f.packet(p.peerMetadataObjects(revisionID: d.revisionID))
        _ = try f.send(negativePacket, context: starlet)
        XCTAssertEqual(try f.receiver.historicalDispositions(for: [b]), [b.revisionID: .demoted])
        let grant = try f.source.configureAccess(
            .object([
                "profile": .text(AccessConfiguration.profile),
                "users": .list([.text("admin"), .text("alice"), .text("bob")]),
            ]), operationID: "three-peer-grant"
        ).revision
        let grantPacket = try f.packet(f.source.peerMetadataObjects(revisionID: grant.revisionID))
        _ = try f.send(grantPacket)
        _ = try f.send(grantPacket, context: f.context, to: p)
        let child = try p.withAccess(forUID: accounts.alice) {
            let parent = try p.get(b.itemID)
            return try p.commit(
                .init(
                    action: .revise, itemID: b.itemID,
                    expectedRevisionID: parent.revisionID,
                    changes: ["subject": .text("post-hold real child")],
                    operationID: "post-hold-child")
            ).revision
        }
        XCTAssertEqual(
            try f.send(
                f.packet(p.peerMetadataObjects(revisionID: child.revisionID)),
                context: starlet
            ).accepted, 1)
        XCTAssertEqual(try f.receiver.get(b.itemID), child)
        _ = try f.send(negativePacket, context: starlet)
        _ = try f.send(negativePacket, context: starlet)
        XCTAssertEqual(try f.receiver.get(b.itemID), child)
        XCTAssertEqual(try f.receiver.historicalDispositions(for: [b]), [b.revisionID: .demoted])
        try f.receiver.rebuildIndex()
        XCTAssertEqual(try f.receiver.get(b.itemID), child)
        try f.capacity()
    }

    func testUnrelatedPendingControlDoesNotEnterLocalPublicationWork() throws {
        let f = try PeerIntakeStoreTests.Fixture()
        try f.bootstrap()
        let missingParent = try f.edit(subject: "missing parent")
        let child = try f.edit(subject: "pending child")
        let objects = try f.source.peerMetadataObjects(revisionID: child.revisionID)
        let blocked = try XCTUnwrap(
            objects.first { pair in
                guard pair.0.kind == .authority,
                    let decoded = try? AuthorityRecordCodec.decode(pair.1),
                    let plan = try? AuthorityStore.VerifiedControlPlan(control: decoded)
                else { return false }
                return plan.deltas.contains { $0.target.revisionID == missingParent.revisionID }
            }
        ).0.id
        XCTAssertEqual(try f.send(f.packet(objects)).missing, 1)
        var inspected: [String] = []
        f.receiver.authorityControlInspectedForTesting = { inspected.append($0) }
        let local = try f.receiver.withAccess(forUID: f.receiverAccounts.alice) {
            try f.receiver.commit(
                .init(
                    classID: "Item", changes: ["subject": .text("independent local")],
                    operationID: "independent-local")
            ).revision
        }
        XCTAssertFalse(
            inspected.contains(blocked), "Unrelated pending control consumes no local publication work.")
        XCTAssertEqual(try f.receiver.get(local.itemID), local)
        XCTAssertEqual(try f.receiver.get(f.base.itemID), f.base)
        try f.capacity()
    }

    func testObservedRevocationParentDoesNotTurnStaleIntentIntoPostGrantAuthority() throws {
        let f = try PeerIntakeStoreTests.Fixture()
        try f.bootstrap()
        let b = try f.edit(uid: f.sourceAccounts.bob)
        let original = try f.source.peerMetadataObjects(revisionID: b.revisionID)
        let oldEvidence = try XCTUnwrap(
            original.first {
                PeerIntakeStoreTests.Fixture.isEvidence($0, for: b.revisionID)
            })
        let evidence = try AuthorityRecordCodec.decode(oldEvidence.1).record
        let r = try f.receiver.configureAccess(
            .object([
                "profile": .text(AccessConfiguration.profile),
                "users": .list([.text("admin"), .text("alice")]),
            ]), operationID: "local-revoke-unseen-b"
        ).revision
        let g = try f.receiver.configureAccess(
            .object([
                "profile": .text(AccessConfiguration.profile),
                "users": .list([.text("admin"), .text("alice"), .text("bob")]),
            ]), operationID: "local-grant-after-r"
        ).revision
        let controls = try f.receiver.peerMetadataObjects(revisionID: g.revisionID)
        let observedR = try XCTUnwrap(
            controls.first { pair in
                guard pair.0.kind == .authority,
                    let value = try? AuthorityRecordCodec.decode(pair.1),
                    let plan = try? AuthorityStore.VerifiedControlPlan(control: value)
                else { return false }
                return plan.deltas.contains { $0.target.revisionID == r.revisionID }
            })
        let extra = try AuthorityRecord(
            recordID: PeerIntakeStoreTests.Fixture.id(),
            storeID: evidence.storeID, originReplicaID: evidence.originReplicaID, kind: .authoredEvidence,
            parentAuthorityIDs: Array(Set(evidence.parentAuthorityIDs + [observedR.0.id])).sorted(),
            actorPrincipal: evidence.actorPrincipal, createdAt: Timestamp.now(), payload: evidence.payload)
        XCTAssertEqual(extra.payload["sourceControl"], evidence.payload["sourceControl"])
        XCTAssertEqual(extra.payload["acceptedAuthority"], .list([]))
        let bytes = try AuthorityRecordCodec.encode(extra)
        let values =
            original.filter { $0.0.id != oldEvidence.0.id } + [
                (
                    PeerPackage.Object(
                        kind: .authority, id: extra.recordID, length: bytes.count,
                        sha256: AuthorityRecordCodec.sha256(bytes)), bytes
                )
            ]
        let result = try f.send(f.packet(values))
        XCTAssertEqual(result.accepted, 0)
        XCTAssertEqual(result.held, 1)
        XCTAssertEqual(try f.receiver.get(b.itemID).revisionID, f.base.revisionID)
        XCTAssertFalse(try f.receiver.history(b.itemID).contains { $0.revisionID == b.revisionID })
        try f.capacity()
    }

}
