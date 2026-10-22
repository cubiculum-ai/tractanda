import CTractandaPlatform
import Foundation
import TractandaCore

/// Startup has no total time budget. Individual probes remain bounded; the operator may cancel.
enum SetupStartupWait {
    struct Observation {
        let detail: String
        var failure: String? = nil
    }
    static func run(
        observe: () throws -> Observation, probe: () throws -> Void,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: () -> Void = { Thread.sleep(forTimeInterval: 0.5) },
        cancelled: () -> Bool = { tractanda_stopping() != 0 },
        report: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) throws {
        var nextObservation = -Double.infinity
        var lastObservation = ""
        var lastError = ""
        while true {
            guard !cancelled() else { throw SetupError("Startup cancelled by the operator.") }
            if now() >= nextObservation {
                let observation: Observation
                do {
                    observation = try observe()
                } catch let timeout as SetupProcessTimeout {
                    if timeout.message != lastError {
                        report("Startup observation: " + timeout.message)
                        lastError = timeout.message
                    }
                    sleep()
                    continue
                }
                if let failure = observation.failure { throw SetupError(failure) }
                if observation.detail != lastObservation {
                    report("Startup: " + observation.detail)
                    lastObservation = observation.detail
                }
                nextObservation = now() + 30
            }
            do {
                try probe()
                return
            } catch {
                let message = (error as? TractandaError)?.description ?? String(describing: error)
                if message != lastError {
                    report("Startup probe: " + message)
                    lastError = message
                }
            }
            guard !cancelled() else { throw SetupError("Startup cancelled by the operator.") }
            sleep()
        }
    }
}
