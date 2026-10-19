import Foundation

/// Pure clock-drift assessment and monotonic scheduling state.
///
/// Callers provide monotonic timestamps, successful NTP offset/uncertainty samples, and randomized
/// intervals. This type performs no networking, waiting, timer creation, or wall-clock adjustment.
public struct PeerClockHealth: Sendable {
    public struct Configuration: Sendable {
        public let referenceHost: String
        public let minimumInterval: TimeInterval
        public let maximumInterval: TimeInterval
        public let minimumProtocolInterval: TimeInterval
        public let timeout: TimeInterval
        public let tolerance: TimeInterval

        public init(
            referenceHost: String = "time.nist.gov",
            minimumInterval: TimeInterval = 1_800,
            maximumInterval: TimeInterval = 3_600,
            minimumProtocolInterval: TimeInterval = 4,
            timeout: TimeInterval = 5,
            tolerance: TimeInterval = 5
        ) {
            self.referenceHost = referenceHost
            self.minimumInterval = minimumInterval
            self.maximumInterval = maximumInterval
            self.minimumProtocolInterval = minimumProtocolInterval
            self.timeout = timeout
            self.tolerance = tolerance
        }
    }

    public enum Assessment: Equatable, Sendable {
        case unknown
        case withinTolerance(offset: TimeInterval, uncertainty: TimeInterval)
        case confirmedOutOfTolerance(offset: TimeInterval, uncertainty: TimeInterval)
        case inconclusive(offset: TimeInterval, uncertainty: TimeInterval)
    }

    public enum Attempt: Equatable, Sendable {
        case none
        case unavailable
        case sampled
    }

    public struct Sample: Equatable, Sendable {
        public let offset: TimeInterval
        public let uncertainty: TimeInterval

        public init(offset: TimeInterval, uncertainty: TimeInterval) {
            self.offset = offset
            self.uncertainty = uncertainty
        }
    }

    public enum Scheduling: Equatable, Sendable {
        case notIdle
        case scheduled(deadline: TimeInterval)
        case due
        case invalidInput
    }

    public private(set) var assessment: Assessment = .unknown
    public private(set) var lastAttempt: Attempt = .none
    public private(set) var nextSampleDeadline: TimeInterval?
    public private(set) var lastConfirmedBadSample: Sample?

    public let configuration: Configuration
    private var hasLatchedBadSample = false
    private var lastMonotonicTime: TimeInterval?

    public var permitsRetirement: Bool {
        !hasLatchedBadSample
    }

    public init(configuration: Configuration = .init()) throws {
        let host = configuration.referenceHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty,
            configuration.minimumProtocolInterval.isFinite,
            configuration.minimumProtocolInterval >= 4,
            configuration.minimumInterval.isFinite,
            configuration.maximumInterval.isFinite,
            configuration.minimumInterval >= configuration.minimumProtocolInterval,
            configuration.maximumInterval >= configuration.minimumInterval,
            configuration.maximumInterval <= 86_400,
            configuration.timeout.isFinite,
            configuration.timeout > 0,
            configuration.timeout <= 60,
            configuration.tolerance.isFinite,
            configuration.tolerance > 0,
            configuration.tolerance <= 3_600
        else {
            throw ConfigurationError.invalid
        }
        self.configuration = Configuration(
            referenceHost: host,
            minimumInterval: configuration.minimumInterval,
            maximumInterval: configuration.maximumInterval,
            minimumProtocolInterval: configuration.minimumProtocolInterval,
            timeout: configuration.timeout,
            tolerance: configuration.tolerance
        )
    }

    /// Schedules only while idle. `interval` is the caller's randomized interval draw.
    public mutating func schedule(
        monotonicNow: TimeInterval,
        isIdle: Bool,
        interval: TimeInterval
    ) -> Scheduling {
        guard acceptsMonotonicTime(monotonicNow) else { return .invalidInput }
        if !isIdle {
            lastMonotonicTime = monotonicNow
            return .notIdle
        }
        guard isValid(interval: interval) else { return .invalidInput }
        lastMonotonicTime = monotonicNow
        if let nextSampleDeadline {
            return nextSampleDeadline <= monotonicNow ? .due : .scheduled(deadline: nextSampleDeadline)
        }
        guard let deadline = safeDeadline(now: monotonicNow, interval: interval) else {
            return .invalidInput
        }
        nextSampleDeadline = deadline
        return .scheduled(deadline: deadline)
    }

    /// Records a successful reference sample, then schedules the next idle sample.
    public mutating func recordSample(
        monotonicNow: TimeInterval,
        offset: TimeInterval,
        uncertainty: TimeInterval,
        nextInterval: TimeInterval
    ) -> Scheduling {
        guard monotonicNow.isFinite,
            offset.isFinite,
            uncertainty.isFinite,
            uncertainty >= 0,
            isValid(interval: nextInterval),
            acceptsMonotonicTime(monotonicNow),
            let deadline = safeDeadline(now: monotonicNow, interval: nextInterval)
        else {
            return .invalidInput
        }

        assessment = assess(offset: offset, uncertainty: uncertainty)
        if case .confirmedOutOfTolerance = assessment {
            hasLatchedBadSample = true
            lastConfirmedBadSample = Sample(offset: offset, uncertainty: uncertainty)
        } else if case .withinTolerance = assessment {
            hasLatchedBadSample = false
            lastConfirmedBadSample = nil
        }
        lastAttempt = .sampled
        nextSampleDeadline = deadline
        lastMonotonicTime = monotonicNow
        return .scheduled(deadline: deadline)
    }

    /// Marks the reference unavailable without erasing a prior confirmed bad assessment.
    public mutating func recordUnavailable(
        monotonicNow: TimeInterval,
        nextInterval: TimeInterval
    ) -> Scheduling {
        guard monotonicNow.isFinite,
            isValid(interval: nextInterval),
            acceptsMonotonicTime(monotonicNow),
            let deadline = safeDeadline(now: monotonicNow, interval: nextInterval)
        else {
            return .invalidInput
        }
        lastAttempt = .unavailable
        nextSampleDeadline = deadline
        lastMonotonicTime = monotonicNow
        return .scheduled(deadline: deadline)
    }

    private func isValid(interval: TimeInterval) -> Bool {
        interval.isFinite
            && interval >= configuration.minimumProtocolInterval
            && interval >= configuration.minimumInterval
            && interval <= configuration.maximumInterval
    }

    private func safeDeadline(now: TimeInterval, interval: TimeInterval) -> TimeInterval? {
        let deadline = now + interval
        return deadline.isFinite && deadline > now ? deadline : nil
    }

    private func acceptsMonotonicTime(_ value: TimeInterval) -> Bool {
        value.isFinite && (lastMonotonicTime.map { value >= $0 } ?? true)
    }

    private func assess(offset: TimeInterval, uncertainty: TimeInterval) -> Assessment {
        let magnitude = abs(offset)
        let tolerance = configuration.tolerance
        if uncertainty <= tolerance, magnitude <= tolerance - uncertainty {
            return .withinTolerance(offset: offset, uncertainty: uncertainty)
        }
        if magnitude > tolerance, uncertainty < magnitude - tolerance {
            return .confirmedOutOfTolerance(offset: offset, uncertainty: uncertainty)
        }
        return .inconclusive(offset: offset, uncertainty: uncertainty)
    }

    private enum ConfigurationError: Error {
        case invalid
    }
}
