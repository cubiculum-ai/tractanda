import Foundation

/// Store-owned private semantic work. Canonical comparison and the complete original PRE are
/// resumable; no physical part or partial semantic result is an acceptance/control transition.
final class AtomicAuthorityControlValidation {
    private let index: ItemIndex
    private let stage: AtomicControlStage
    private let structural: AtomicAuthorityStageValidation
    private let validateSupport:
        (
            AuthorityStore.DispositionDelta, AuthorityStore.HistoricalEligibility,
            AtomicAuthorityOriginalPRE
        ) throws -> Void
    private let currentContext: () throws -> String
    private let contextDigest: String
    private let validateCurrentRights: () throws -> Void
    private let reconstruction: AtomicAuthorityAcceptance.Sealed?
    let validationPurpose: AtomicAuthorityAcceptance.ValidationPurpose
    private var parentCursor: Int64 = -1
    private var parentsComplete = false
    private(set) var waitingForControl: AuthorityBinding?
    private var cursor: Int64 = -1
    private var support: LogicalControlSource.Support?
    private var originalPRE: AtomicAuthorityOriginalPRE?
    private var priorTarget: AuthorityStore.Target?
    private var priorOutcome: Bool?
    private var reducedPRE: AuthorityStore.HistoricalEligibility?
    private(set) var complete = false
    private var failed = false
    private var closed = false
    private(set) var validatedFacts: Int64 = 0
    private var completedOriginalPREUnits: Int64 = 0
    var originalPREProcessedUnitsForTesting: Int64 {
        completedOriginalPREUnits + (originalPRE?.processedUnits ?? 0)
    }
    var canonicalComparedFacts: Int64 { structural.comparedFacts }
    var header: LogicalControlSource.Header { stage.header }
    var expectedContextSHA256: String { contextDigest }
    var waitingForPart: AuthorityBinding? { structural.waitingForPart }

    /// Store-owned current semantic context, including the real originating actor when a
    /// native receiver issues local admission. No caller can substitute the service account.
    func freshContextDigest() throws -> String { try currentContext() }

    init(
        index: ItemIndex, stage: AtomicControlStage, structural: AtomicAuthorityStageValidation,
        contextDigest: String, currentContext: @escaping () throws -> String,
        validateCurrentRights: @escaping () throws -> Void,
        reconstruction: AtomicAuthorityAcceptance.Sealed? = nil,
        validationPurpose: AtomicAuthorityAcceptance.ValidationPurpose = .authenticatedRequest,
        validateSupport:
            @escaping (
                AuthorityStore.DispositionDelta, AuthorityStore.HistoricalEligibility,
                AtomicAuthorityOriginalPRE
            ) throws -> Void
    ) throws {
        self.index = index
        self.stage = stage
        self.structural = structural
        self.contextDigest = try AuthorityRecord.digest(.text(contextDigest))
        self.currentContext = currentContext
        self.validateCurrentRights = validateCurrentRights
        self.reconstruction = reconstruction
        self.validationPurpose = validationPurpose
        if let reconstruction {
            guard reconstruction.receipt.root == stage.header.binding,
                reconstruction.bytesSHA256 == contextDigest
            else {
                throw AtomicAuthorityFormat.invalid(
                    "Historical work must bind the exact existing accepted receipt.")
            }
        }
        self.validateSupport = validateSupport
        guard try currentContext() == contextDigest else {
            throw AtomicAuthorityFormat.invalid("Atomic semantic context changed before validation.")
        }
    }
    deinit { try? close() }

    /// One native work call borrows its enclosing budget. Completion of immutable parsing does
    /// not reset it; a nil/pending PRE state is a healthy private yield, never invalid authority.
    func step(maximumUnits: Int = 64) throws -> Bool {
        guard !closed, !failed, (1...128).contains(maximumUnits) else {
            throw AtomicAuthorityFormat.invalid("Closed/failed atomic semantic work.")
        }
        do {
            return try index.withCatalogueScanBudget(reusingActiveBudget: true) {
                try checkContext()
                if complete { return true }
                guard try structural.step(maximumFacts: maximumUnits) else { return false }
                let source = LogicalControlSource.atomic(stage)
                // Missing complete logical parents are resumable dependency work, not an
                // invalid ordinary approval. Physical parts never satisfy this gate.
                if !parentsComplete {
                    let parents = try source.parents(
                        index: index, afterOrdinal: parentCursor,
                        limit: maximumUnits)
                    for parent in parents {
                        guard try index.hasValidatedAuthorityControl(parent.binding) else {
                            waitingForControl = parent.binding
                            return false
                        }
                        waitingForControl = nil
                        parentCursor = parent.ordinal
                    }
                    if !parents.isEmpty { return false }
                    parentsComplete = true
                }
                for _ in 0..<maximumUnits {
                    guard try index.atomicPrivateWindowHasRoom(minimumVMInstructions: 16_384) else {
                        return false
                    }
                    if support == nil {
                        guard
                            let next = try source.supports(index: index, afterOrdinal: cursor, limit: 1).first
                        else {
                            try checkContext()
                            complete = true
                            return true
                        }
                        support = next
                        if priorTarget?.revisionID != next.delta.target.revisionID {
                            completedOriginalPREUnits = try AtomicAuthorityFormat.sum(
                                completedOriginalPREUnits, originalPRE?.processedUnits ?? 0)
                            try originalPRE?.close()
                            originalPRE = try .init(index: index, source: source, target: next.delta.target)
                            priorTarget = next.delta.target
                            priorOutcome = next.delta.eligible
                            reducedPRE = nil
                        } else {
                            guard priorTarget == next.delta.target, priorOutcome == next.delta.eligible else {
                                throw AtomicAuthorityFormat.invalid(
                                    "One atomic target has contradictory support outcomes.")
                            }
                        }
                    }
                    guard let support, let originalPRE else {
                        throw AtomicAuthorityFormat.invalid("Atomic semantic cursor lost its exact fact.")
                    }
                    if reducedPRE == nil {
                        reducedPRE = try originalPRE.step(maximumUnits: maximumUnits)
                        if reducedPRE == nil { return false }
                    }
                    try validateSupport(support.delta, reducedPRE!, originalPRE)
                    cursor = support.ordinal
                    validatedFacts += 1
                    self.support = nil
                }
                try checkContext()
                return false
            }
        } catch {
            failed = true
            try? close()
            throw error
        }
    }

    /// No caller can receive a VerifiedAtomicControlPlan before full byte binding and semantic
    /// validation. Store rechecks current rights/context inside this final writer phase, seals
    /// canonical proof first, and only then activates the derived root in the same transaction.
    func withFinalWriter<T>(
        _ body: (AuthorityStore.VerifiedAtomicControlPlan) throws -> T
    ) throws -> T {
        guard complete, !failed, !closed else {
            throw AtomicAuthorityFormat.invalid("Atomic semantic work is incomplete.")
        }
        defer { try? close() }
        return try structural.withFinalWriter(existingAcceptance: reconstruction) { _ in
            try self.checkContext()
            try self.validateCurrentRights()
            try self.checkContext()
            let previous = self.index.activeAtomicOriginalPREContains
            if let pre = self.originalPRE {
                self.index.activeAtomicOriginalPREContains = pre.contains
            } else {
                self.index.activeAtomicOriginalPREContains = nil
            }
            defer { self.index.activeAtomicOriginalPREContains = previous }
            return try body(
                .init(
                    stage: self.stage, contextDigest: self.contextDigest,
                    reconstruction: self.reconstruction, validationPurpose: self.validationPurpose))
        }
    }
    private func checkContext() throws {
        try Task.checkCancellation()
        guard try currentContext() == contextDigest else {
            throw AtomicAuthorityFormat.invalid(
                "Current atomic semantic context changed; private work must be revalidated.")
        }
    }
    func close() throws {
        guard !closed else { return }
        closed = true
        defer { try? structural.close() }
        try originalPRE?.close()
        originalPRE = nil
    }
}
