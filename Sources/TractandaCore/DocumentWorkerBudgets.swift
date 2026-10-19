import Foundation

/// Operational resources are separate from semantic converter/model/source identity.
struct DocumentWorkerBudgets: Sendable {
    let inspect: Double
    let modelLoad: Double
    let page: Double
    let noProgress: Double
    let terminationGrace: Double
    init(
        inspect: Double = DocumentJobResources.defaultInspectSeconds,
        modelLoad: Double = DocumentJobResources.defaultModelLoadSeconds,
        page: Double = DocumentJobResources.defaultPageSeconds,
        noProgress: Double = DocumentJobResources.defaultNoProgressSeconds,
        terminationGrace: Double = DocumentJobResources.defaultTerminationGraceSeconds
    ) throws {
        guard
            [inspect, modelLoad, page, noProgress, terminationGrace].allSatisfy({
                $0.isFinite && $0 > 0 && $0 < Double(Int64.max) / 1_000_000_000
            }), terminationGrace <= 60
        else {
            throw TractandaError(
                "invalidDocumentConfiguration", "Native phase budgets must be positive and addressable.")
        }
        self.inspect = inspect
        self.modelLoad = modelLoad
        self.page = page
        self.noProgress = noProgress
        self.terminationGrace = terminationGrace
    }
}

/// One phase/page, never the whole document. Caller renews only after strict valid progress.
struct DocumentWorkerDeadline {
    enum Phase: String { case inspect, modelLoad, page, finish }
    let budgets: DocumentWorkerBudgets
    private(set) var phase: Phase
    private var started: ContinuousClock.Instant
    private var lastProgress: ContinuousClock.Instant
    private var silentCompute = false
    init(budgets: DocumentWorkerBudgets, phase: Phase, now: ContinuousClock.Instant = .now) {
        self.budgets = budgets
        self.phase = phase
        started = now
        lastProgress = now
    }
    mutating func begin(_ phase: Phase, now: ContinuousClock.Instant = .now) {
        self.phase = phase
        started = now
        lastProgress = now
        silentCompute = false
    }
    mutating func observe(meaningful: Bool, workerPhase: String? = nil, now: ContinuousClock.Instant = .now) {
        if let workerPhase {
            silentCompute = ["modelLoad", "render", "prepare", "prefill"].contains(workerPhase)
        }
        if meaningful { lastProgress = now }
    }
    private var phaseSeconds: Double {
        let seconds: Double
        switch phase {
        case .inspect: seconds = budgets.inspect
        case .modelLoad: seconds = budgets.modelLoad
        case .page: seconds = budgets.page
        case .finish: seconds = budgets.noProgress
        }
        return seconds
    }
    private var usesProgressDeadline: Bool {
        !silentCompute
    }
    var deadline: ContinuousClock.Instant {
        if !usesProgressDeadline { return started.advanced(by: .seconds(phaseSeconds)) }
        return min(
            started.advanced(by: .seconds(phaseSeconds)),
            lastProgress.advanced(by: .seconds(budgets.noProgress)))
    }
    /// Safe bounded context captured at failure, before termination can add cleanup time.
    func timeoutFailure(lastPhase: String?, now: ContinuousClock.Instant = .now) -> TractandaError {
        let noProgress =
            usesProgressDeadline
            && lastProgress.advanced(by: .seconds(budgets.noProgress))
                < started.advanced(by: .seconds(phaseSeconds))
        let origin = noProgress ? lastProgress : started
        let duration = origin.duration(to: now).components
        let elapsed = max(0, Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
        let limit = noProgress ? budgets.noProgress : phaseSeconds
        // The phase comes only from strictly validated worker progress, never inferred counters.
        return TractandaError(
            "documentTimeout",
            "Native worker operational budget expired. phase=\(lastPhase ?? "unknown"); "
                + "timeout=\(noProgress ? "noProgress" : phase.rawValue); "
                + "budgetSeconds=\(limit); elapsedSeconds=\(elapsed).")
    }
}
