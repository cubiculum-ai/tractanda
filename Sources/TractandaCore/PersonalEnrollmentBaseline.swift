import Foundation

/// Host-private observation emitted only by the finite-cut owner, never decoded from a
/// request or persisted as authority. A process/job generation resets after interruption.
package struct PersonalEnrollmentCompletedCut: Sendable {
    package let storeID: String
    package let targetReplicaID: String
    package let sourceReplicaID: String
    package let configurationDigest: String
    package let selectionID: String
    package let jobGeneration: UUID
    package let ordinal: UInt64
    package let sourceCatalogueGeneration: String
    package let cutRowID: Int64
    package init(binding: PeerExchangeBinding, selectionID: String, jobGeneration: UUID,
        ordinal: UInt64, sourceCatalogueGeneration: String, cutRowID: Int64) throws {
        try PersonalSyncValidation.identifier(selectionID)
        guard ordinal > 0, !sourceCatalogueGeneration.isEmpty, sourceCatalogueGeneration.utf8.count <= 200,
            cutRowID >= 0 else { throw PersonalEnrollmentError.invalid() }
        storeID = binding.storeID; targetReplicaID = binding.localReplicaID; sourceReplicaID = binding.remoteReplicaID
        configurationDigest = binding.configurationDigest; self.selectionID = selectionID
        self.jobGeneration = jobGeneration; self.ordinal = ordinal
        self.sourceCatalogueGeneration = sourceCatalogueGeneration; self.cutRowID = cutRowID
    }
}

/// Explicit, non-Codable proof of two actual selected-source cuts from one runtime job.
/// General process-lifetime status counters cannot construct a valid generation pair.
package struct PersonalEnrollmentBaselineReadiness: Sendable {
    package let storeID: String
    package let targetReplicaID: String
    package let sourceReplicaID: String
    package let configurationDigest: String
    package let selectionID: String
    private init(_ cut: PersonalEnrollmentCompletedCut) {
        storeID = cut.storeID; targetReplicaID = cut.targetReplicaID; sourceReplicaID = cut.sourceReplicaID
        configurationDigest = cut.configurationDigest; selectionID = cut.selectionID
    }
    package static func observed(first: PersonalEnrollmentCompletedCut,
        rescan: PersonalEnrollmentCompletedCut) throws -> Self {
        guard first.storeID == rescan.storeID, first.targetReplicaID == rescan.targetReplicaID,
            first.sourceReplicaID == rescan.sourceReplicaID, first.configurationDigest == rescan.configurationDigest,
            first.selectionID == rescan.selectionID, first.jobGeneration == rescan.jobGeneration,
            first.ordinal < rescan.ordinal, first.sourceCatalogueGeneration == rescan.sourceCatalogueGeneration,
            first.cutRowID <= rescan.cutRowID else {
            throw TractandaError("baselineNotReady", "Initial cut and rescan do not belong to the same selected runtime job.")
        }
        return .init(rescan)
    }
}
