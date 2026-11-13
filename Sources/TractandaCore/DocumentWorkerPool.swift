import Dispatch
import Foundation

/// Resource observations only: a running worker need not have loaded model weights yet.
public struct DocumentWorkerPoolStatus: Codable, Sendable {
    public let workerRunning: Bool
    public let documentActive: Bool
    public let unloadPending: Bool
}

/// One serial document lease and at most one native process. The private queue owns idle
/// supervision; a lease exclusively owns process I/O until release. No Store crosses this boundary.
final class DocumentWorkerPool: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ai.tractanda.document-worker-pool")
    private let idleSeconds: Double
    private var process: DocumentOwnedProcess?
    private var key: Key?
    private var leased = false
    private var retire = false
    private var closed = false
    private var generation: UInt64 = 0
    private var timer: DispatchSourceTimer?
    private struct Key: Equatable {
        let executable: String
        let executableSHA256: String
        let modelDirectory: String
    }

    static func validateIdleSeconds(_ seconds: Double) throws {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int64.max) / 1_000_000_000 else {
            throw TractandaError(
                "invalidDocumentConfiguration", "Worker idle retention must be finite and nonnegative.")
        }
    }
    init(idleSeconds: Double) throws {
        try Self.validateIdleSeconds(idleSeconds)
        self.idleSeconds = idleSeconds
    }
    deinit {
        timer?.cancel()
        process?.terminateAndWait()
    }
    func acquire(
        configuration: DocumentConverterConfiguration, executableSHA256: String,
        cancellation: DocumentConversionCancellation, graceSeconds: Double,
        deadline: ContinuousClock.Instant
    ) throws -> DocumentOwnedProcess {
        try queue.sync {
            guard !closed, !leased else {
                throw TractandaError(
                    "documentWorkerBusy", "The document worker already has an owner or is closed.")
            }
            try cancellation.check()
            let requested = Key(
                executable: configuration.executablePath, executableSHA256: executableSHA256,
                modelDirectory: configuration.modelDirectory)
            timer?.cancel()
            timer = nil
            generation &+= 1
            process?.reapIfExited()
            if key != requested || retire || process?.terminationStatus != nil { destroyIdle() }
            if process == nil {
                process = try DocumentOwnedProcess(
                    executable: configuration.executablePath,
                    arguments: ["pool-v1", configuration.modelDirectory],
                    cancellation: cancellation, graceSeconds: graceSeconds)
                do {
                    guard
                        let greeting = try process!.nextLine(
                            limit: NativeWorkerProtocol.controlBytes, deadline: deadline)
                    else { throw NativeWorkerProtocol.invalid() }
                    try NativeWorkerProtocol.poolGreeting(greeting)
                } catch {
                    destroyIdle()
                    if error is CancellationError || error is DocumentWorkerDeadlineExpired { throw error }
                    throw TractandaError(
                        "documentWorkerPoolUnsupported",
                        "Configured document worker did not advertise the required native pool protocol.")
                }
                key = requested
            }
            let worker = process!
            worker.beginLease(cancellation: cancellation)
            leased = true
            return worker
        }
    }
    func release(_ worker: DocumentOwnedProcess, healthy: Bool) {
        queue.sync {
            guard process === worker, leased else { return }
            leased = false
            if !healthy || retire || closed || idleSeconds == 0 {
                destroyIdle()
                return
            }
            generation &+= 1
            let captured = generation
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + idleSeconds)
            timer.setEventHandler { [weak self] in
                guard let self, !self.leased, self.generation == captured else { return }
                self.destroyIdle()
            }
            self.timer = timer
            timer.resume()
        }
    }
    /// Idle workers retire immediately; active work completes its current document safely.
    func unload(authorize: @escaping @Sendable () throws -> Void = {}) async throws
        -> DocumentWorkerPoolStatus
    {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    try authorize()
                    retire = leased
                    if !leased { destroyIdle() }
                    continuation.resume(returning: statusOnQueue())
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func status() async -> DocumentWorkerPoolStatus {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: statusOnQueue()) }
        }
    }
    func shutdown() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                closed = true
                retire = leased
                if !leased { destroyIdle() }
                continuation.resume()
            }
        }
    }
    private func statusOnQueue() -> DocumentWorkerPoolStatus {
        if !leased, let process, process.reapIfExited() { destroyIdle() }
        return DocumentWorkerPoolStatus(
            workerRunning: process != nil, documentActive: leased, unloadPending: retire)
    }
    private func destroyIdle() {
        precondition(!leased)
        generation &+= 1
        timer?.cancel()
        timer = nil
        process?.terminateAndWait()
        process = nil
        key = nil
        retire = false
    }
}
