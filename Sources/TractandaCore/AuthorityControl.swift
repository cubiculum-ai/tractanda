import Foundation
import TractandaClient

public typealias AuthorityBinding = TractandaClient.AuthorityBinding

extension AuthorityStore {
    static let causalCapability = "tractanda.authority-causal.v1"
    static let reconciliationProfile = "tractanda.authority-reconciliation.v1"
    struct Target: Equatable, Sendable {
        let itemID: String
        let revisionID: String
        let sha256: String
        init(value: ItemValue) throws {
            let b = try AuthorityRecord.binding(value)
            itemID = b.itemID
            revisionID = b.revisionID
            sha256 = b.sha256
        }
        init(itemID: String, revisionID: String, sha256: String) throws {
            try self.init(
                value: .object([
                    "itemID": .text(itemID), "revisionID": .text(revisionID), "sha256": .text(sha256),
                ]))
        }
        var itemValue: ItemValue {
            .object(["itemID": .text(itemID), "revisionID": .text(revisionID), "sha256": .text(sha256)])
        }
    }
    struct DispositionDelta: Equatable, Sendable {
        let target: Target
        let eligible: Bool
        let actor: String
        let policyIDs: [String]
        let causes: [AuthorityBinding]
        let evidence: AuthorityBinding?
        init(
            target: Target, eligible: Bool, actor: String, policyIDs: [String],
            causes: [AuthorityBinding] = [], evidence: AuthorityBinding? = nil
        ) {
            self.target = target
            self.eligible = eligible
            self.actor = actor
            self.policyIDs = policyIDs
            self.causes = causes
            self.evidence = evidence
        }
        init(value: ItemValue) throws {
            let f = try AuthorityRecord.object(
                value, keys: ["target", "eligible", "actor", "policies", "causes", "evidence"])
            guard let eligible = f["eligible"]?.booleanValue else {
                throw TractandaError("invalidAuthority", "Missing eligibility transition.")
            }
            self.init(
                target: try Target(value: f["target"]!), eligible: eligible,
                actor: try AuthorityRecord.text(f["actor"]),
                policyIDs: try AuthorityRecord.ids(f["policies"]),
                causes: try AuthorityRecord.list(f["causes"]).map(AuthorityBinding.init(value:)),
                evidence: try AuthorityRecord.list(f["evidence"]).first.map(AuthorityBinding.init(value:)))
        }
        var itemValue: ItemValue {
            .object([
                "target": target.itemValue, "eligible": .boolean(eligible), "actor": .text(actor),
                "policies": .list(policyIDs.map(ItemValue.text)), "causes": .list(causes.map(\.itemValue)),
                "evidence": .list(evidence.map { [$0.itemValue] } ?? []),
            ])
        }
    }
    enum HistoricalEligibility: String, Sendable { case eligible, held, unknown }
    /// Trusted Store boundary: source intent/authority and exact package receipt are validated
    /// before this plan is passed to Index. Index independently binds every field to these bytes.
    struct VerifiedControlPlan: Equatable, Sendable {
        let control: AuthorityRecordCodec.Verified
        let parents: [AuthorityBinding]
        let localParent: AuthorityBinding?
        let deltas: [DispositionDelta]
        let bootstrap: AuthorityBinding?
        init(control: AuthorityRecordCodec.Verified) throws {
            guard control.record.kind.rawValue == "controlCommit" else {
                throw TractandaError("invalidAuthority", "Expected control commit.")
            }
            self.control = control
            parents = try AuthorityRecord.list(control.record.payload["controls"]).map(
                AuthorityBinding.init(value:))
            localParent = try AuthorityRecord.list(control.record.payload["localParent"]).first.map(
                AuthorityBinding.init(value:))
            deltas = try AuthorityRecord.list(control.record.payload["deltas"]).map(
                DispositionDelta.init(value:))
            bootstrap = try AuthorityRecord.list(control.record.payload["bootstrap"]).first.map(
                AuthorityBinding.init(value:))
        }
        var binding: AuthorityBinding {
            try! .init(recordID: control.record.recordID, sha256: control.sha256)
        }
    }
    struct VerifiedInvalidationPlan: Sendable {
        let control: AuthorityBinding
        let sourceCut: AuthorityBinding
        let policy: AuthorityRevision
        let previousPolicyID: String
    }
    struct Invalidation: Equatable, Sendable {
        let control: AuthorityBinding
        let sourceCut: AuthorityBinding
        let policy: Target
        let previousPolicyID: String
    }
    struct Exposure: Equatable, Sendable {
        let witness: AuthorityBinding
        let target: Target
        let cut: AuthorityBinding
        let modifiedAt: String
        let causeKey: String?
    }
    struct VerifiedExposurePlan: Equatable, Sendable {
        let witness: AuthorityRecordCodec.Verified
        let target: Target
        let cut: AuthorityBinding
        let modifiedAt: String
        let causeKey: String?
        init(witness: AuthorityRecordCodec.Verified) throws {
            guard witness.record.kind.rawValue == "visibilityWitness" else {
                throw TractandaError("invalidAuthority", "Expected visibility witness.")
            }
            self.witness = witness
            target = try Target(value: witness.record.payload["target"]!)
            cut = try AuthorityBinding(value: witness.record.payload["cut"]!)
            guard let at = witness.record.payload["modifiedAt"]?.dateString else {
                throw TractandaError("invalidAuthority", "Missing visibility time.")
            }
            _ = try RevisionTimestamp(at)
            modifiedAt = at
            causeKey = try AuthorityRecord.list(witness.record.payload["causeKey"]).first.map {
                try AuthorityRecord.digest($0)
            }
        }
    }
    struct VerifiedReconciliationPlan: Equatable, Sendable {
        let witness: AuthorityRecordCodec.Verified
        let itemID: String
        let parents: [String]
        let frontier: [String]
        let causes: [AuthorityBinding]
        let exposures: [AuthorityBinding]
        let baseFloor: String
        let modifiedAt: String
        let outputRevisionID: String
        let planDigest: String
        init(witness: AuthorityRecordCodec.Verified) throws {
            guard witness.record.kind.rawValue == "reconciliationWitness" else {
                throw TractandaError("invalidAuthority", "Expected reconciliation witness.")
            }
            let f = witness.record.payload
            self.witness = witness
            itemID = try AuthorityRecord.persistentID(f["itemID"])
            parents = try AuthorityRecord.ids(f["parents"], maximum: 1024)
            frontier = try AuthorityRecord.ids(f["frontier"], maximum: 1024)
            causes = try AuthorityRecord.list(f["causes"]).map(AuthorityBinding.init(value:))
            exposures = try AuthorityRecord.list(f["exposures"]).map(AuthorityBinding.init(value:))
            baseFloor = f["baseFloor"]!.dateString!
            modifiedAt = f["modifiedAt"]!.dateString!
            _ = try RevisionTimestamp(baseFloor)
            _ = try RevisionTimestamp(modifiedAt)
            outputRevisionID = try AuthorityRecord.persistentID(f["outputRevisionID"])
            planDigest = try AuthorityRecord.digest(f["planDigest"])
        }
    }
    struct ReconciliationReservation: Equatable, Sendable {
        let key: String
        let revisionID: String
        let witness: AuthorityBinding
        let outputDigest: String?
    }
}
