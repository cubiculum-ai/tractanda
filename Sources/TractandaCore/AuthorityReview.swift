import Foundation

extension AuthorityStore {
    static let reviewCapability = "tractanda.authority-review.v1"

    enum ReviewDisposition: String, Sendable {
        case approved, held, conflicted, unknown
    }

    struct ReviewState: Sendable {
        let original: Target
        let evidence: AuthorityBinding
        let stateToken: String
        let decisionFrontier: [AuthorityBinding]
        let controlHolds: [AuthorityBinding]
        let policyFrontier: [Target]
        let current: ItemState
        var retirements: [AuthorityBinding] = []
    }
    struct ReviewRequest: Codable, Sendable {
        let itemID: String
        let revisionID: String
        let evidence: AuthorityBinding
        let expectedStateToken: String
        let reviewedFrontier: [AuthorityBinding]
        let reviewedControlHolds: [AuthorityBinding]
        let changes: [String: ItemValue]
        let unset: [String]
        let operationID: String
        var reviewedRetirements: [AuthorityBinding] = []
    }
    struct ReviewResult: Sendable {
        let revision: Revision
        let decision: AuthorityBinding
        let wasReplayed: Bool
        let current: ItemState
        let disposition: ReviewDisposition
    }
    /// Internal bounded storage/corpus preparation, never an authority decision or a
    /// successful pending ReviewResult. The handle binds exact authenticated intent.
    struct ReviewPreflight: Sendable {
        let handle: String
        let ready: Bool
    }

    /// Store validates source/current administrator authority and the sealed closure before
    /// runtime registration. Recovery registration is explicitly provisional until C's own
    /// parent context and complete record have passed the existing disk graph validator.
    struct VerifiedReviewEvent: Equatable, Sendable {
        let record: AuthorityRecordCodec.Verified
        let target: Target
        let evidence: AuthorityBinding
        let parents: [AuthorityBinding]
        let preCut: AuthorityBinding
        let resolution: Target
        let controlHolds: [AuthorityBinding]
        let retirements: [AuthorityBinding]

        init(record: AuthorityRecordCodec.Verified, parents: [AuthorityBinding]) throws {
            guard record.record.kind == .reviewDecision,
                record.record.payload["decision"] == .text("accept"),
                try AuthorityRecord.list(record.record.payload["sourceControl"]).count == 1,
                try AuthorityRecord.list(record.record.payload["resolution"]).count == 1
            else {
                throw TractandaError("invalidAuthority", "Atomic review requires its PRE cut and fresh C.")
            }
            self.record = record
            target = try Target(value: record.record.payload["target"]!)
            evidence = try AuthorityBinding(value: record.record.payload["evidence"]!)
            self.parents = parents
            preCut = try AuthorityBinding(
                value: AuthorityRecord.list(record.record.payload["sourceControl"])[0])
            resolution = try Target(value: AuthorityRecord.list(record.record.payload["resolution"])[0])
            controlHolds = try AuthorityRecord.list(record.record.payload["controlHolds"]).map(
                AuthorityBinding.init(value:))
            retirements = try AuthorityRecord.list(record.record.payload["retirements"] ?? .list([])).map(
                AuthorityBinding.init(value:))
            guard target.itemID == resolution.itemID, target.revisionID != resolution.revisionID,
                parents.map(\.recordID)
                    == (try AuthorityRecord.ids(record.record.payload["decisionFrontier"])),
                Set(
                    [preCut.recordID] + parents.map(\.recordID) + controlHolds.map(\.recordID)
                        + retirements.map(\.recordID)
                )
                .isSubset(of: record.record.parentAuthorityIDs)
            else { throw TractandaError("invalidAuthority", "Review context/target dependency mismatch.") }
        }
        var binding: AuthorityBinding {
            try! .init(recordID: record.record.recordID, sha256: record.sha256)
        }
    }

    /// No future canonical locator is asserted here. Preview receives real metadata from a
    /// private immutable draft file; apply receives the actual sealed canonical C row.
    struct VerifiedReviewPlan: Sendable {
        let event: VerifiedReviewEvent
        let held: AuthorityRevision
        let heldRow: ItemIndex.CatalogueRow
        let resolution: AuthorityRevision
        let evidence: AuthorityRecordCodec.Verified
        let control: VerifiedControlPlan
        let policyFrontier: [Target]
        let operationID: String

        init(
            event: VerifiedReviewEvent, held: AuthorityRevision, heldRow: ItemIndex.CatalogueRow,
            resolution: AuthorityRevision, evidence: AuthorityRecordCodec.Verified,
            control: VerifiedControlPlan, policyFrontier: [Target], operationID: String
        ) throws {
            self.event = event
            self.held = held
            self.heldRow = heldRow
            self.resolution = resolution
            self.evidence = evidence
            self.control = control
            self.policyFrontier = policyFrontier
            self.operationID = operationID
            guard event.target.itemID == held.revision.itemID,
                event.target.revisionID == held.revision.revisionID, event.target.sha256 == held.sha256,
                event.resolution.itemID == resolution.revision.itemID,
                event.resolution.revisionID == resolution.revision.revisionID,
                event.resolution.sha256 == resolution.sha256,
                evidence.record.kind == .authoredEvidence,
                try AuthorityRecord.binding(evidence.record.payload["target"]).revisionID
                    == resolution.revision.revisionID,
                try AuthorityRecord.binding(evidence.record.payload["target"]).sha256 == resolution.sha256,
                try AuthorityRecord.list(evidence.record.payload["acceptedAuthority"]) == [
                    event.binding.itemValue
                ],
                try AuthorityRecord.list(evidence.record.payload["sourceControl"]) == [
                    event.preCut.itemValue
                ],
                evidence.record.actorPrincipal == event.record.record.actorPrincipal,
                evidence.record.originReplicaID == event.record.record.originReplicaID,
                Set(try held.revision.provenance!.writtenFields + held.revision.provenance!.unsetFields)
                    .isSubset(
                        of: Set(
                            try resolution.revision.provenance!.writtenFields
                                + resolution.revision.provenance!.unsetFields)),
                resolution.revision.fields["operationID"]?.string == operationID,
                try resolution.revision.provenance?.kind == .resolution,
                control.control.record.originReplicaID == evidence.record.originReplicaID,
                control.parents.contains(event.preCut),
                control.deltas.count == 2,
                control.deltas.allSatisfy({ $0.eligible }),
                control.deltas.contains(where: { $0.target == event.target && $0.evidence == event.evidence }
                ),
                control.deltas.contains(where: {
                    $0.target == event.resolution
                        && $0.evidence
                            == (try? AuthorityBinding(
                                recordID: evidence.record.recordID, sha256: evidence.sha256))
                })
            else {
                throw TractandaError(
                    "invalidAuthority", "Atomic review closure differs from exact D/B/C evidence.")
            }
        }
    }
}

extension AuthorityStore {
    /// Private reservation, never a replicated authority fact. Exact IDs and times survive
    /// preparation/seal failures; the journal seal alone determines committed publication.
    struct ReviewIdentity: Codable {
        let profile: String
        let storeID: String
        let replicaID: String
        let actor: String
        let request: String
        let packageID: String
        let revisionID: String
        let decisionID: String
        let evidenceID: String
        let controlID: String
        let visibilityID: String
        let createdAt: String
        let modifiedAt: String
        let preCut: AuthorityBinding
    }
}

extension AuthorityStore {
    /// Shared domain preflight before seal and exact Index registration after apply.
    /// This validates a transition shape, not authority to publish or historical acceptance.
    static func validateReviewPolicyTransition(_ plan: VerifiedReviewPlan, previous: AuthorityRevision) throws
    {
        let c = plan.resolution.revision
        let old = previous.revision
        try ItemSemantics.validate(c)
        try ItemSemantics.validate(old)
        let target = try Target(itemID: old.itemID, revisionID: old.revisionID, sha256: previous.sha256)
        guard old.itemID == c.itemID, plan.policyFrontier.contains(target), let provenance = try c.provenance
        else {
            throw TractandaError(
                "invalidAuthority", "Review transition omitted its exact PRE policy original.")
        }
        let field: String
        if c.classID == AccessConfiguration.classID || old.classID == AccessConfiguration.classID {
            guard c.classID == AccessConfiguration.classID, old.classID == AccessConfiguration.classID,
                old.fields["accessConfiguration"] != c.fields["accessConfiguration"]
            else {
                throw TractandaError(
                    "invalidAuthority", "Review cannot invent/retype an access-configuration transition.")
            }
            field = "accessConfiguration"
        } else {
            guard old.fields["permissions"] != c.fields["permissions"] else {
                throw TractandaError("invalidAuthority", "Review policy pair has no permission transition.")
            }
            field = "permissions"
        }
        guard
            c.fields[field] == nil
                ? provenance.unsetFields.contains(field) : provenance.writtenFields.contains(field)
        else {
            throw TractandaError(
                "invalidAuthority", "Review policy transition was not an explicit fresh C choice.")
        }
    }
}
