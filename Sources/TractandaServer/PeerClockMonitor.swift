import Foundation
import TractandaCore

/// Driven by existing maintenance ticks. One idle-start sample may overlap ordinary requests.
/// These injectable closures are local test seams, never request-selected providers.
actor PeerClockMonitor {
    typealias Lease = ServiceCoordinator.PeerClockRuntimeLease
    typealias Prepare = @Sendable (Double, Double, PeerClockHealth.Configuration) async throws -> Lease?
    typealias Finish = @Sendable (Lease, PeerClockHealth.Sample?, Double, Double) async throws -> Void
    typealias Sample = @Sendable (PeerClockHealth.Configuration) async throws -> PeerClockHealth.Sample
    private let configuration: PeerClockHealth.Configuration
    private let prepare: Prepare
    private let finish: Finish
    private let sample: Sample
    private let now: @Sendable () -> Double
    private let draw: @Sendable (ClosedRange<Double>) -> Double
    private var admission = false
    private var running: Task<Void, Never>?
    private var stopped = false

    init(
        configuration: PeerClockHealth.Configuration = .init(), prepare: @escaping Prepare,
        finish: @escaping Finish, sample: @escaping Sample,
        now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
        draw: @escaping @Sendable (ClosedRange<Double>) -> Double = { Double.random(in: $0) }
    ) {
        self.configuration = configuration
        self.prepare = prepare
        self.finish = finish
        self.sample = sample
        self.now = now
        self.draw = draw
    }
    func tick() async {
        guard !stopped, !admission, running == nil else { return }
        admission = true
        defer { admission = false }
        let interval = draw(configuration.minimumInterval...configuration.maximumInterval)
        guard let lease = try? await prepare(now(), interval, configuration) else { return }
        guard !stopped else { return }
        running = Task { [self] in
            let evidence = try? await sample(lease.configuration)
            if !Task.isCancelled {
                let next = draw(lease.configuration.minimumInterval...lease.configuration.maximumInterval)
                try? await finish(lease, evidence, now(), next)
            }
            completed()
        }
    }
    private func completed() { running = nil }
    func close() async {
        stopped = true
        let current = running
        current?.cancel()
        await current?.value
    }
    func isRunningForTesting() -> Bool { running != nil }
}
