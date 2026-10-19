import XCTest

@testable import TractandaCore

final class AuthorityEligibilityTests: XCTestCase {
    private struct Fixture {
        let store = try! UUID.makeVersion1().uuidString.lowercased()
        let origin = try! UUID.makeVersion1().uuidString.lowercased()
        let item = try! UUID.makeVersion1().uuidString.lowercased()
        func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }
        func revision(parent: AuthorityRevision? = nil, subject: String = "root", legacy: Bool = false) throws
            -> AuthorityRevision
        {
            var fields: [String: ItemValue] =
                parent?.revision.fields ?? [
                    "classID": .text("Item"), "schemaVersion": .integer(1),
                    "createdAt": .date("2026-10-13T12:00:00.000Z"),
                ]
            fields["itemID"] = .text(item)
            fields["revisionID"] = .text(try id())
            fields["subject"] = .text(subject)
            fields["actor"] = .text("user:alice")
            fields["operationID"] = .text(try id())
            fields["requestIdentity"] = .text("fixture")
            fields["modifiedAt"] = .date(
                parent == nil
                    ? "2026-10-13T12:00:00.000Z"
                    : try RevisionPublicationClock.after(
                        [parent!.revision.modifiedAt], now: { "2026-10-13T12:00:00.000Z" }))
            fields.removeValue(forKey: "revisionAncestry")
            if let parent { fields["supersedes"] = .text(parent.revision.revisionID) }
            if !legacy {
                fields["revisionAncestry"] = try RevisionProvenance(
                    kind: .authored, originReplicaID: origin,
                    parents: parent.map { [$0.revision.revisionID] } ?? [],
                    writtenFields: parent == nil
                        ? fields.keys.filter { !RevisionMerge.managedFields.contains($0) }.sorted()
                        : ["subject"],
                    unsetFields: [], frontier: []
                ).itemValue
            }
            return try .init(
                originalBytes: RecordCodec.encode(Revision(fields: fields, formatVersion: legacy ? 1 : 2)))
        }
        func binding(_ node: AuthorityRevision) -> ItemValue {
            .object([
                "itemID": .text(node.revision.itemID), "revisionID": .text(node.revision.revisionID),
                "sha256": .text(node.sha256),
            ])
        }
        func ref(_ node: AuthorityRecordCodec.Verified) -> ItemValue {
            .object(["recordID": .text(node.record.recordID), "sha256": .text(node.sha256)])
        }
        func record(
            _ kind: AuthorityRecord.Kind, payload: [String: ItemValue], parents: [String] = [],
            recordID: String? = nil
        ) throws -> AuthorityRecordCodec.Verified {
            try AuthorityRecordCodec.decode(
                AuthorityRecordCodec.encode(
                    AuthorityRecord(
                        recordID: recordID ?? id(), storeID: store, originReplicaID: origin, kind: kind,
                        parentAuthorityIDs: parents.sorted(), actorPrincipal: "alice",
                        createdAt: "2026-10-13T12:00:00.000Z", payload: payload)))
        }
        func evidence(
            _ node: AuthorityRevision, parent: AuthorityRevision? = nil, observed: [String] = [],
            accepted: [AuthorityRecordCodec.Verified] = []
        )
            throws -> AuthorityRecordCodec.Verified
        {
            let provenance = try node.revision.provenance!
            return try record(
                .authoredEvidence,
                payload: [
                    "target": binding(node), "parents": .list(node.parents.map(ItemValue.text)),
                    "frontier": .list((parent.map { [$0.revision.revisionID] } ?? []).map(ItemValue.text)),
                    "itemPolicies": .list(parent.map { [binding($0)] } ?? []), "admissionPolicies": .list([]),
                    "principal": .text("alice"), "sourceUID": .integer(501),
                    "groups": .object(["staff": .integer(20)]), "aliases": .object([:]),
                    "rights": .list([.text("write")]), "evaluated": .boolean(true),
                    "acceptedAuthority": .list(
                        accepted.map(ref).sorted {
                            $0.map!["recordID"]!.string! < $1.map!["recordID"]!.string!
                        }),
                    "intent": .object([
                        "writtenFields": .list(provenance.writtenFields.map(ItemValue.text)),
                        "unsetFields": .list(provenance.unsetFields.map(ItemValue.text)),
                    ]),
                ], parents: observed)
        }
        func attested(_ nodes: [AuthorityRecordCodec.Verified]) throws -> [AuthorityEligibility.Attested] {
            let peer = try TrustedAuthorityPeer(peerName: "fixture", storeID: store, origins: [origin])
            return nodes.map { .init(authority: $0, peer: peer) }
        }
        func decision(
            _ node: AuthorityRevision, evidence: AuthorityRecordCodec.Verified, accept: Bool,
            previous: [AuthorityRecordCodec.Verified] = [], holds: [AuthorityRecordCodec.Verified] = []
        ) throws -> AuthorityRecordCodec.Verified {
            try record(
                .reviewDecision,
                payload: [
                    "target": binding(node), "evidence": ref(evidence),
                    "holds": .list(
                        holds.map { .text($0.record.recordID) }.sorted { $0.string! < $1.string! }),
                    "decisionFrontier": .list(
                        previous.map { .text($0.record.recordID) }.sorted { $0.string! < $1.string! }),
                    "decision": .text(accept ? "accept" : "reject"), "administrationPolicies": .list([]),
                    "itemPolicies": .list([]), "reason": .text("explicit fixture review"),
                ],
                parents: [evidence.record.recordID] + previous.map { $0.record.recordID }
                    + holds.map { $0.record.recordID })
        }
        func reduce(
            _ nodes: [AuthorityRevision], _ records: [AuthorityRecordCodec.Verified],
            revocations: [String] = [], current: AuthorityEligibility.Verdict = .allowed,
            administrator: AuthorityEligibility.Verdict = .allowed,
            initialBootstrap: AuthorityRecordCodec.Verified? = nil
        ) throws -> [String: AuthorityEligibility.Disposition] {
            let peer = try TrustedAuthorityPeer(peerName: "fixture", storeID: store, origins: [origin])
            let pin = try initialBootstrap.flatMap {
                try AuthorityEligibility.pinInitialBootstrap(
                    $0, peer: peer,
                    administrator: { _ in
                        .init(source: .allowed, current: administrator, invalidatingRevocations: [])
                    })
            }
            return try AuthorityEligibility.reduce(
                revisions: nodes, records: attested(records), initialBootstrap: pin,
                evaluate: { node, _ in
                    .init(
                        source: .allowed, current: current,
                        invalidatingRevocations: node.revision.fields["subject"]?.string == "edit"
                            ? revocations : [])
                },
                currentAdministrator: { _ in
                    .init(source: .allowed, current: administrator, invalidatingRevocations: [])
                })
        }
    }
    private func code(_ expected: String, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body()) { XCTAssertEqual(($0 as? TractandaError)?.code, expected) }
    }
    func testStrictCodecRetainsBytesAndRejectsUnknownAmbiguousEnvelope() throws {
        let f = Fixture()
        let root = try f.revision()
        let evidence = try f.evidence(root)
        XCTAssertEqual(try AuthorityRecordCodec.decode(evidence.originalBytes), evidence)
        XCTAssertEqual(try AuthorityRecordCodec.encode(evidence.record), evidence.originalBytes)
        var value = evidence.record.itemValue.map!
        value["extra"] = .boolean(true)
        code("invalidAuthority") { _ = try AuthorityRecord(value: .object(value)) }
        let text = String(decoding: evidence.originalBytes, as: UTF8.self)
        code("invalidAuthority") {
            _ = try AuthorityRecordCodec.decode(
                Data(text.replacingOccurrences(of: "X-Store-ID:", with: "X-Wrong-ID:").utf8))
        }
        code("invalidAuthority") {
            _ = try AuthorityRecordCodec.decode(
                Data(
                    text.replacingOccurrences(
                        of: "MIME-Version: 1.0", with: "MIME-Version: 1.0\r\nMIME-Version: 1.0"
                    ).utf8))
        }
        code("invalidAuthority") {
            _ = try AuthorityRecordCodec.decode(
                Data(
                    text.replacingOccurrences(of: "tractanda.authority.v1", with: "tractanda.authority.v9")
                        .utf8))
        }
    }
    func testExactIntentDigestOriginAndReservedControlBindings() throws {
        let f = Fixture()
        let root = try f.revision()
        let evidence = try f.evidence(root)
        var payload = evidence.record.payload
        payload["target"] = .object([
            "itemID": .text(f.item), "revisionID": .text(root.revision.revisionID),
            "sha256": .text(String(repeating: "a", count: 64)),
        ])
        let forged = try f.record(.authoredEvidence, payload: payload)
        code("invalidAuthority") { _ = try f.reduce([root], [forged]) }
        payload = evidence.record.payload
        payload["intent"] = .object(["writtenFields": .list([]), "unsetFields": .list([])])
        let wrongIntent = try f.record(.authoredEvidence, payload: payload)
        code("invalidAuthority") { _ = try f.reduce([root], [wrongIntent]) }
        let other = try TrustedAuthorityPeer(peerName: "other", storeID: f.store, origins: [f.id()])
        let held = try AuthorityEligibility.reduce(
            revisions: [root], records: [.init(authority: evidence, peer: other)],
            evaluate: { _, _ in .init(source: .allowed, current: .allowed, invalidatingRevocations: []) },
            currentAdministrator: { _ in
                .init(source: .allowed, current: .allowed, invalidatingRevocations: [])
            })
        XCTAssertEqual(held[root.revision.revisionID], .unknownAuthority)
        var fields = root.revision.fields
        fields["authorityEvidence"] = .text(evidence.record.recordID)
        fields["revisionAncestry"] = try RevisionProvenance(
            kind: .authored, originReplicaID: f.origin, parents: [],
            writtenFields: fields.keys.filter { !RevisionMerge.managedFields.contains($0) }.sorted(),
            unsetFields: [], frontier: []
        ).itemValue
        code("invalidAuthority") {
            _ = try AuthorityRevision(
                originalBytes: RecordCodec.encode(Revision(fields: fields, formatVersion: 2)))
        }
    }
    func testLateConcurrentRevocationDemotesPriorEligibleEditAndDependentChild() throws {
        let f = Fixture()
        let root = try f.revision()
        let edit = try f.revision(parent: root, subject: "edit")
        let child = try f.revision(parent: edit, subject: "child")
        let revocation = try f.revision(parent: root, subject: "revoke")
        let records = try [
            f.evidence(root), f.evidence(edit, parent: root), f.evidence(child, parent: edit),
            f.evidence(revocation, parent: root),
        ]
        XCTAssertEqual(
            try f.reduce([root, edit, child], Array(records.prefix(3)))[edit.revision.revisionID], .eligible)
        let after = try f.reduce(
            [root, edit, child, revocation], records, revocations: [revocation.revision.revisionID])
        XCTAssertEqual(after[edit.revision.revisionID], .reviewRequired)
        XCTAssertEqual(after[child.revision.revisionID], .missingDependencies)
        XCTAssertEqual(
            after,
            try f.reduce(
                [revocation, child, edit, root], records.reversed(),
                revocations: [revocation.revision.revisionID]))
    }
    func testAncestorPreservationAndUnrelatedLaterGrantNotRetroactive() throws {
        let f = Fixture()
        let root = try f.revision()
        let edit = try f.revision(parent: root, subject: "edit")
        let revocation = try f.revision(parent: edit, subject: "revoke")
        let records = try [
            f.evidence(root), f.evidence(edit, parent: root), f.evidence(revocation, parent: edit),
        ]
        XCTAssertEqual(
            try f.reduce([root, edit, revocation], records, revocations: [revocation.revision.revisionID])[
                edit.revision.revisionID], .eligible)
        let concurrent = try f.revision(parent: root, subject: "revoke")
        let grant = try f.revision(parent: concurrent, subject: "grant")
        let more = try [f.evidence(concurrent, parent: root), f.evidence(grant, parent: concurrent)]
        XCTAssertEqual(
            try f.reduce(
                [root, edit, concurrent, grant], Array(records.prefix(2)) + more,
                revocations: [concurrent.revision.revisionID], current: .allowed)[edit.revision.revisionID],
            .reviewRequired)
        let afterRevoke = try f.revision(parent: concurrent, subject: "edit")
        let seen = try f.evidence(afterRevoke, parent: concurrent)
        XCTAssertEqual(
            try f.reduce(
                [root, concurrent, afterRevoke], [records[0], more[0], seen],
                revocations: [concurrent.revision.revisionID])[afterRevoke.revision.revisionID],
            .reviewRequired)
    }
    func testChangedPolicyBasisWithValidEffectiveRightsRemainsEligible() throws {
        let f = Fixture()
        let root = try f.revision()
        let policy = try f.revision(parent: root, subject: "equivalent policy")
        let edit = try f.revision(parent: policy, subject: "edit")
        let records = try [
            f.evidence(root), f.evidence(policy, parent: root), f.evidence(edit, parent: policy),
        ]
        XCTAssertEqual(try f.reduce([root, policy, edit], records)[edit.revision.revisionID], .eligible)
        XCTAssertEqual(
            try f.reduce([root, policy, edit], records, current: .unknown)[edit.revision.revisionID],
            .unknownAuthority)
    }
    func testExplicitInitialBootstrapNeedsEveryPageAndExactCut() throws {
        let f = Fixture()
        let root = try f.revision(legacy: true)
        let next = try f.revision(parent: root, subject: "new")
        let manifestID = try f.id()
        let page = try f.record(
            .bootstrapPage,
            payload: [
                "manifestID": .text(manifestID),
                "entries": .list([
                    .object(["target": f.binding(root), "frontier": .list([.text(root.revision.revisionID)])])
                ]),
            ])
        let manifest = try f.record(
            .bootstrap,
            payload: [
                "pages": .list([f.ref(page)]), "initial": .boolean(true), "administrationPolicies": .list([]),
            ], parents: [page.record.recordID], recordID: manifestID)
        XCTAssertEqual(try f.reduce([root], [])[root.revision.revisionID], .unknownAuthority)
        XCTAssertEqual(try f.reduce([root], [manifest])[root.revision.revisionID], .unknownAuthority)
        let result = try f.reduce([root, next], [manifest, page], initialBootstrap: manifest)
        XCTAssertEqual(result[root.revision.revisionID], .eligible)
        XCTAssertEqual(result[next.revision.revisionID], .unknownAuthority)
        XCTAssertEqual(try f.reduce([root], [manifest, page])[root.revision.revisionID], .unknownAuthority)
        XCTAssertEqual(
            try f.reduce([root], [manifest, page], administrator: .unknown, initialBootstrap: manifest)[
                root.revision.revisionID],
            .unknownAuthority)
    }
    func testInitialCutDoesNotImmunizeConcurrentEditFromNewRevocation() throws {
        let f = Fixture()
        let root = try f.revision(legacy: true)
        let edit = try f.revision(parent: root, subject: "edit", legacy: true)
        let revoke = try f.revision(parent: root, subject: "revoke")
        let manifestID = try f.id()
        let entries = [root, edit].sorted { $0.revision.revisionID < $1.revision.revisionID }.map {
            ItemValue.object(["target": f.binding($0), "frontier": .list([.text($0.revision.revisionID)])])
        }
        let page = try f.record(
            .bootstrapPage, payload: ["manifestID": .text(manifestID), "entries": .list(entries)])
        let manifest = try f.record(
            .bootstrap,
            payload: [
                "pages": .list([f.ref(page)]), "initial": .boolean(true), "administrationPolicies": .list([]),
            ], parents: [page.record.recordID], recordID: manifestID)
        XCTAssertEqual(
            try f.reduce([root, edit], [page, manifest], initialBootstrap: manifest)[
                edit.revision.revisionID], .eligible)
        let after = try f.reduce(
            [root, edit, revoke], [page, manifest, f.evidence(revoke, parent: root)],
            revocations: [revoke.revision.revisionID], initialBootstrap: manifest)
        XCTAssertEqual(after[root.revision.revisionID], .eligible)
        XCTAssertEqual(after[edit.revision.revisionID], .reviewRequired)
    }

    func testReviewDecisionsConflictThenResolveOwnContextWithoutGrantMutation() throws {
        let f = Fixture()
        let root = try f.revision()
        let edit = try f.revision(parent: root, subject: "edit")
        let revoke = try f.revision(parent: root, subject: "revoke")
        let evidence = try f.evidence(edit, parent: root)
        let basic = try [f.evidence(root), evidence, f.evidence(revoke, parent: root)]
        let approve = try f.decision(edit, evidence: evidence, accept: true)
        let reject = try f.decision(edit, evidence: evidence, accept: false)
        let nodes = [root, edit, revoke]
        XCTAssertEqual(
            try f.reduce(nodes, basic + [approve], revocations: [revoke.revision.revisionID])[
                edit.revision.revisionID], .approved)
        XCTAssertEqual(
            try f.reduce(nodes, basic + [approve, reject], revocations: [revoke.revision.revisionID])[
                edit.revision.revisionID], .reviewRequired)
        let final = try f.decision(edit, evidence: evidence, accept: true, previous: [approve, reject])
        XCTAssertEqual(
            try f.reduce(nodes, basic + [final, reject, approve], revocations: [revoke.revision.revisionID])[
                edit.revision.revisionID], .approved)
        XCTAssertEqual(edit.originalBytes, try RecordCodec.encode(edit.revision))
        XCTAssertEqual(
            try f.reduce(
                nodes, basic + [approve], revocations: [revoke.revision.revisionID], administrator: .unknown)[
                    edit.revision.revisionID], .unknownAuthority)
        var payload = final.record.payload
        payload["decisionFrontier"] = .list([.text(approve.record.recordID)])
        let omitted = try f.record(
            .reviewDecision, payload: payload, parents: final.record.parentAuthorityIDs)
        code("invalidAuthority") { _ = try f.reduce(nodes, basic + [approve, reject, omitted]) }
    }
    func testHoldBindsActualRevocationAndRejectionBlocksDescendant() throws {
        let f = Fixture()
        let root = try f.revision()
        let edit = try f.revision(parent: root, subject: "edit")
        let child = try f.revision(parent: edit, subject: "child")
        let revoke = try f.revision(parent: root, subject: "revoke")
        let evidence = try f.evidence(edit, parent: root)
        let basic = try [
            f.evidence(root), evidence, f.evidence(child, parent: edit), f.evidence(revoke, parent: root),
        ]
        let hold = try f.record(
            .reviewHold,
            payload: [
                "target": f.binding(edit), "evidence": f.ref(evidence),
                "revocations": .list([f.binding(revoke)]), "decisionFrontier": .list([]),
                "reason": .text("revoked"),
            ], parents: [evidence.record.recordID])
        let reject = try f.decision(edit, evidence: evidence, accept: false, holds: [hold])
        let result = try f.reduce(
            [root, edit, child, revoke], basic + [hold, reject], revocations: [revoke.revision.revisionID])
        XCTAssertEqual(result[edit.revision.revisionID], .rejected)
        XCTAssertEqual(result[child.revision.revisionID], .missingDependencies)
        code("invalidAuthority") { _ = try f.reduce([root, edit, child, revoke], basic + [hold]) }
    }
    func testAutomaticMaterializationRequiresEveryEligibleParentWithoutHumanGrant() throws {
        let f = Fixture()
        let root = try f.revision()
        let a = try f.revision(parent: root, subject: "same")
        let b = try f.revision(parent: root, subject: "same")
        var fields = a.revision.fields
        fields["revisionID"] = .text(try f.id())
        fields["operationID"] = .text(try f.id())
        fields["actor"] = .text("system")
        fields["modifiedAt"] = .date(
            try RevisionPublicationClock.after(
                [a.revision.modifiedAt, b.revision.modifiedAt], now: { "2026-10-13T12:00:00.000Z" }))
        fields.removeValue(forKey: "supersedes")
        fields["revisionAncestry"] = try RevisionProvenance(
            kind: .automaticMerge, originReplicaID: f.origin,
            parents: [a.revision.revisionID, b.revision.revisionID].sorted(), writtenFields: [],
            unsetFields: [],
            frontier: [a.revision.revisionID, b.revision.revisionID].sorted(),
            mergeProfile: RevisionMerge.profile
        ).itemValue
        let merge = try AuthorityRevision(
            originalBytes: RecordCodec.encode(Revision(fields: fields, formatVersion: 2)))
        let evidence = try [f.evidence(root), f.evidence(a, parent: root)]
        let missing = try f.reduce([root, a, b, merge], evidence)
        XCTAssertEqual(missing[b.revision.revisionID], .unknownAuthority)
        XCTAssertEqual(missing[merge.revision.revisionID], .missingDependencies)
        XCTAssertEqual(
            try f.reduce([root, a, b, merge], evidence + [f.evidence(b, parent: root)])[
                merge.revision.revisionID], .eligible)
    }
    func testHistoricalReviewSurvivesOnlyCausallyAttestedAcceptedAdminRevocation() throws {
        let f = Fixture()
        let root = try f.revision()
        let edit = try f.revision(parent: root, subject: "edit")
        let evidence = try f.evidence(edit, parent: root)
        let decision = try f.decision(edit, evidence: evidence, accept: true)
        let revocation = try f.revision(parent: root, subject: "admin revoke")
        let basic = try [f.evidence(root), evidence, decision]
        let observed = try f.evidence(revocation, parent: root, observed: [decision.record.recordID])
        let accepted = try f.evidence(
            revocation, parent: root, observed: [decision.record.recordID], accepted: [decision])
        func reduce(_ witness: AuthorityRecordCodec.Verified) throws -> [String: AuthorityEligibility
            .Disposition]
        {
            try AuthorityEligibility.reduce(
                revisions: [root, edit, revocation], records: f.attested(basic + [witness]),
                evaluate: { _, _ in
                    .init(source: .allowed, current: .allowed, invalidatingRevocations: [])
                },
                currentAdministrator: { _ in
                    .init(
                        source: .allowed, current: .denied,
                        invalidatingRevocations: [revocation.revision.revisionID])
                })
        }
        XCTAssertEqual(try reduce(observed)[edit.revision.revisionID], .unknownAuthority)
        XCTAssertEqual(try reduce(accepted)[edit.revision.revisionID], .approved)
        let concurrent = try f.evidence(revocation, parent: root)
        XCTAssertEqual(try reduce(concurrent)[edit.revision.revisionID], .unknownAuthority)
    }
    func testNewHoldPreventsOldApprovalUntilFreshDecisionConsumesIt() throws {
        let f = Fixture()
        let root = try f.revision()
        let edit = try f.revision(parent: root, subject: "edit")
        let revoke = try f.revision(parent: root, subject: "revoke")
        let evidence = try f.evidence(edit, parent: root)
        let old = try f.decision(edit, evidence: evidence, accept: true)
        let basic = try [f.evidence(root), evidence, f.evidence(revoke, parent: root)]
        let hold = try f.record(
            .reviewHold,
            payload: [
                "target": f.binding(edit), "evidence": f.ref(evidence),
                "revocations": .list([f.binding(revoke)]),
                "decisionFrontier": .list([.text(old.record.recordID)]),
                "reason": .text("new invalidating context"),
            ], parents: [evidence.record.recordID, old.record.recordID])
        let nodes = [root, edit, revoke]
        XCTAssertEqual(
            try f.reduce(nodes, basic + [old], revocations: [revoke.revision.revisionID])[
                edit.revision.revisionID], .approved)
        XCTAssertEqual(
            try f.reduce(nodes, basic + [old, hold], revocations: [revoke.revision.revisionID])[
                edit.revision.revisionID], .reviewRequired)
        let fresh = try f.decision(edit, evidence: evidence, accept: true, previous: [old], holds: [hold])
        XCTAssertEqual(
            try f.reduce(nodes, basic + [fresh, hold, old], revocations: [revoke.revision.revisionID])[
                edit.revision.revisionID], .approved)
        var missing = fresh.record.payload
        missing["holds"] = .list([])
        let omitted = try f.record(
            .reviewDecision, payload: missing, parents: fresh.record.parentAuthorityIDs)
        code("invalidAuthority") {
            _ = try f.reduce(nodes, basic + [old, hold, omitted], revocations: [revoke.revision.revisionID])
        }
    }
    func testAuthorizedDecisionCanConsumePreviouslyUncertainOrDeniedDecision() throws {
        let f = Fixture()
        let root = try f.revision()
        let edit = try f.revision(parent: root, subject: "edit")
        let revoke = try f.revision(parent: root, subject: "revoke")
        let evidence = try f.evidence(edit, parent: root)
        let old = try f.decision(edit, evidence: evidence, accept: true)
        let fresh = try f.decision(edit, evidence: evidence, accept: true, previous: [old])
        let basic = try [f.evidence(root), evidence, f.evidence(revoke, parent: root)]
        for verdict: AuthorityEligibility.Verdict in [.unknown, .denied] {
            let result = try AuthorityEligibility.reduce(
                revisions: [root, edit, revoke], records: f.attested(basic + [old, fresh]),
                evaluate: { node, _ in
                    .init(
                        source: .allowed, current: .allowed,
                        invalidatingRevocations: node.revision.revisionID == edit.revision.revisionID
                            ? [revoke.revision.revisionID] : [])
                },
                currentAdministrator: { record in
                    .init(
                        source: .allowed,
                        current: record.recordID == old.record.recordID ? verdict : .allowed,
                        invalidatingRevocations: [])
                })
            XCTAssertEqual(result[edit.revision.revisionID], .approved)
        }
    }
    func testDuplicateMissingDependencyLimitsAndCancellation() throws {
        let f = Fixture()
        let root = try f.revision()
        let edit = try f.revision(parent: root, subject: "edit")
        let evidence = try f.evidence(edit, parent: root)
        XCTAssertEqual(try f.reduce([edit], [evidence])[edit.revision.revisionID], .missingDependencies)
        let rootEvidence = try f.evidence(root)
        XCTAssertEqual(
            try f.reduce([root, root], [rootEvidence, rootEvidence])[root.revision.revisionID], .eligible)
        var limit = AuthorityEligibility.Limits()
        limit.maximumWork = 1
        code("resourceLimit") {
            _ = try AuthorityEligibility.reduce(
                revisions: [root], records: f.attested([rootEvidence]), limits: limit,
                evaluate: { _, _ in .init(source: .allowed, current: .allowed, invalidatingRevocations: []) },
                currentAdministrator: { _ in
                    .init(source: .allowed, current: .allowed, invalidatingRevocations: [])
                })
        }
        limit.maximumWork = 1_000_000
        limit.maximumBytes = 1
        code("resourceLimit") {
            _ = try AuthorityEligibility.reduce(
                revisions: [root], records: f.attested([rootEvidence]), limits: limit,
                evaluate: { _, _ in .init(source: .allowed, current: .allowed, invalidatingRevocations: []) },
                currentAdministrator: { _ in
                    .init(source: .allowed, current: .allowed, invalidatingRevocations: [])
                })
        }
        code("cancelled") {
            _ = try AuthorityEligibility.reduce(
                revisions: [root], records: [], progress: { throw TractandaError("cancelled", "fixture") },
                evaluate: { _, _ in .init(source: .allowed, current: .allowed, invalidatingRevocations: []) },
                currentAdministrator: { _ in
                    .init(source: .allowed, current: .allowed, invalidatingRevocations: [])
                })
        }
    }
}
