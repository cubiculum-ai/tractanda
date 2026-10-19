import Foundation
import TractandaCore
import TractandaPeerTransport

/// Opt-in owner of finite jobs. Pairing roles select initiators; each job exchanges both ways.
actor PeerSyncRuntime {
    private struct Edge {
        let id: UUID
        let snapshot: PeerRuntimeSnapshot
        let driver: PeerSyncDriver
        var next: Double
        var failures = 0
        var blocked = false
        var lastReport: PeerSyncDriver.Report?
    }
    private struct Job { let id: UUID; let task: Task<Void, Never> }
    private let configuration: PeerRuntimeConfiguration
    private let coordinator: ServiceCoordinator
    private let network: PeerServiceRuntime
    private let limits: PeerSyncLimits
    private let synchronizeForTesting: (@Sendable (String, PeerRuntimeSnapshot) async throws -> PeerSyncDriver.Report)?
    private var edges: [String: Edge] = [:]
    private var jobs: [String: Job] = [:]
    private var refresh: Task<Void, Never>?
    private var refreshRequest = UUID()
    private var nextRefresh: Double = 0
    private var cursor = 0
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var stopped = false
    private var active = false
    private(set) var lastErrorCode: String?
    private(set) var maximumObservedJobs = 0

    init(configuration: PeerRuntimeConfiguration, coordinator: ServiceCoordinator,
        network: PeerServiceRuntime, limits: PeerSyncLimits = .init(),
        synchronizeForTesting: (@Sendable (String, PeerRuntimeSnapshot) async throws -> PeerSyncDriver.Report)? = nil) throws {
        try limits.validate()
        self.configuration = configuration; self.coordinator = coordinator
        self.network = network; self.limits = limits
        self.synchronizeForTesting = synchronizeForTesting
    }
    func activate() { if !stopped { active = configuration.synchronization.enabled } }
    func tick(now: Double = ProcessInfo.processInfo.systemUptime) {
        guard active, !stopped else { return }
        lastTick = now
        if refresh == nil, now >= nextRefresh {
            nextRefresh = now + 1
            refresh = Task { [self] in await refreshNow(); refresh = nil }
        }
        schedule()
    }
    private func refreshNow() async {
        let request = UUID(); refreshRequest = request
        do {
            let snapshot = try await coordinator.loadPeerRuntimeSnapshot()
            try Task.checkCancellation()
            guard active, !stopped, refreshRequest == request else { return }
            let configured = Set(configuration.peers.map(\.alias))
            let eligible = snapshot.credentials.filter { $0.binding.localIsInitiator && configured.contains($0.binding.peerID) }
            var retained: [String: Edge] = [:]
            for credential in eligible {
                let peer = credential.binding.peerID
                if let old = edges[peer], old.snapshot.hasSameAdmission(as: snapshot) { retained[peer] = old }
                else {
                    jobs[peer]?.task.cancel()
                    retained[peer] = try Edge(id: UUID(), snapshot: snapshot,
                        driver: PeerSyncDriver(coordinator: coordinator, binding: credential.binding, limits: limits), next: lastTick)
                }
            }
            for peer in edges.keys where retained[peer] == nil { jobs[peer]?.task.cancel() }
            let retired = edges.filter { retained[$0.key]?.id != $0.value.id }.map(\.value)
            edges = retained
            for edge in retired { await edge.driver.close() }
            guard !stopped, refreshRequest == request else { return }
            lastErrorCode = nil
            schedule()
        } catch {
            guard !stopped, refreshRequest == request else { return }
            lastErrorCode = (error as? TractandaError)?.code ?? "peerSyncUnavailable"
            for job in jobs.values { job.task.cancel() }
            let retired = Array(edges.values); edges = [:]
            for edge in retired { await edge.driver.close() }
        }
    }
    private func schedule() {
        guard active, !stopped, jobs.count < 2 else { return }
        let peers = edges.keys.sorted()
        guard !peers.isEmpty else { return }
        let start = cursor
        for offset in 0..<peers.count {
            guard jobs.count < 2 else { break }
            let index = (start + offset) % peers.count, peer = peers[index]
            guard let edge = edges[peer], !edge.blocked, jobs[peer] == nil, edge.next <= lastTick else { continue }
            let id = UUID(), task = Task { [self] in
                let result: Result<PeerSyncDriver.Report, Error>
                do {
                    try await coordinator.validatePeerRuntimeSnapshot(edge.snapshot)
                    let report: PeerSyncDriver.Report
                    if let synchronizeForTesting { report = try await synchronizeForTesting(peer, edge.snapshot) }
                    else { report = try await network.synchronize(peerID: peer, driver: edge.driver) }
                    try Task.checkCancellation()
                    try await coordinator.validatePeerRuntimeSnapshot(edge.snapshot)
                    result = .success(report)
                } catch { result = .failure(error) }
                finished(peer: peer, jobID: id, edgeID: edge.id, result: result)
            }
            jobs[peer] = Job(id: id, task: task)
            maximumObservedJobs = max(maximumObservedJobs, jobs.count)
            cursor = (index + 1) % peers.count
        }
    }
    private func finished(peer: String, jobID: UUID, edgeID: UUID, result: Result<PeerSyncDriver.Report, Error>) {
        guard jobs[peer]?.id == jobID else { return }
        jobs.removeValue(forKey: peer) // The task finished network close/cancellation before releasing its slot.
        guard !stopped, var edge = edges[peer], edge.id == edgeID else { schedule(); return }
        switch result {
        case .success(let report):
            edge.lastReport = report; edge.failures = 0
            edge.blocked = [.repairRequired, .unsupported].contains(report.status)
            if report.status == .yielded { edge.next = lastTick + 0.25 }
            else {
                edge.next = lastTick + min(86_400, Double(configuration.synchronization.intervalSeconds) * Double.random(in: 1...1.2))
            }
        case .failure(let error):
            if Task.isCancelled { edge.next = lastTick + 1 }
            else {
                edge.failures = min(16, edge.failures + 1)
                edge.next = lastTick + min(300, 5 * pow(2, Double(min(8, edge.failures - 1))) * Double.random(in: 0.8...1.2))
                lastErrorCode = (error as? TractandaError)?.code ?? "peerSyncUnavailable"
            }
        }
        edges[peer] = edge
        schedule()
    }
    /// Explicit future operator retry after repair; no external route is supplied by this unit.
    func retry(peerID: String) async {
        guard var edge = edges[peerID], !stopped else { return }
        await edge.driver.retry()
        guard !stopped, edges[peerID]?.id == edge.id else { return }
        edge.blocked = false; edge.next = lastTick; edges[peerID] = edge
        schedule()
    }
    func close() async {
        stopped = true; active = false; refreshRequest = UUID()
        refresh?.cancel()
        for job in jobs.values { job.task.cancel() }
        let owned = Array(jobs.values), peers = Array(edges.keys)
        for job in owned { await job.task.value }
        await refresh?.value
        for peer in peers { await network.closeSynchronizationConnection(peerID: peer) }
        for edge in edges.values { await edge.driver.close() }
        jobs = [:]; edges = [:]; refresh = nil
    }
    func operatorStatus() throws -> PeerSynchronizationStatus {
        var outcomes: [String: Int] = [:]
        for edge in edges.values {
            if let report = edge.lastReport { outcomes[report.status.rawValue, default: 0] += 1 }
        }
        return try .init(state: stopped ? .stopped : !configuration.synchronization.enabled ? .disabled
            : active ? .active : .unavailable, activeJobCount: jobs.count,
            eligibleEdgeCount: edges.count, outcomeCounts: outcomes, lastErrorCode: lastErrorCode)
    }

    func schedulingForTesting(peerID: String) -> (failures: Int, next: Double)? {
        edges[peerID].map { ($0.failures, $0.next) }
    }
    func reportsForTesting() -> [String: PeerSyncDriver.Report] { edges.compactMapValues(\.lastReport) }
    func activeJobsForTesting() -> Int { jobs.count }
}
