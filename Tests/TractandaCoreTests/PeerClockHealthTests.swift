import XCTest

@testable import TractandaCore

final class PeerClockHealthTests: XCTestCase {
    func testIdleSchedulingUsesInjectedMonotonicTimeAndRandomizedInterval() throws {
        var health = try PeerClockHealth()

        XCTAssertEqual(health.schedule(monotonicNow: 100, isIdle: false, interval: 2_400), .notIdle)
        XCTAssertNil(health.nextSampleDeadline)
        XCTAssertEqual(
            health.schedule(monotonicNow: 100, isIdle: true, interval: 2_400),
            .scheduled(deadline: 2_500)
        )
        XCTAssertEqual(
            health.schedule(monotonicNow: 2_499, isIdle: true, interval: 3_000), .scheduled(deadline: 2_500))
        XCTAssertEqual(health.schedule(monotonicNow: 2_500, isIdle: true, interval: 1_800), .due)
        XCTAssertEqual(health.nextSampleDeadline, 2_500)
    }

    func testUncertaintySeparatesHealthyBadAndInconclusiveBoundaries() throws {
        var health = try PeerClockHealth()

        _ = health.recordSample(monotonicNow: 0, offset: 4, uncertainty: 1, nextInterval: 1_800)
        XCTAssertEqual(health.assessment, .withinTolerance(offset: 4, uncertainty: 1))
        XCTAssertTrue(health.permitsRetirement)

        _ = health.recordSample(monotonicNow: 10, offset: 7, uncertainty: 2, nextInterval: 1_800)
        XCTAssertEqual(health.assessment, .inconclusive(offset: 7, uncertainty: 2))
        XCTAssertTrue(health.permitsRetirement)

        _ = health.recordSample(monotonicNow: 20, offset: -7.01, uncertainty: 2, nextInterval: 1_800)
        XCTAssertEqual(health.assessment, .confirmedOutOfTolerance(offset: -7.01, uncertainty: 2))
        XCTAssertFalse(health.permitsRetirement)
    }

    func testUnavailableAttemptPreservesBadAssessmentAndGoodSampleRecovers() throws {
        var health = try PeerClockHealth()
        _ = health.recordSample(monotonicNow: 1, offset: 8, uncertainty: 1, nextInterval: 1_800)
        XCTAssertFalse(health.permitsRetirement)
        let confirmedBad = PeerClockHealth.Sample(offset: 8, uncertainty: 1)
        XCTAssertEqual(health.lastConfirmedBadSample, confirmedBad)

        XCTAssertEqual(
            health.recordUnavailable(monotonicNow: 2, nextInterval: 3_600),
            .scheduled(deadline: 3_602)
        )
        XCTAssertEqual(health.lastAttempt, .unavailable)
        XCTAssertEqual(health.assessment, .confirmedOutOfTolerance(offset: 8, uncertainty: 1))
        XCTAssertFalse(health.permitsRetirement)
        XCTAssertEqual(health.lastConfirmedBadSample, confirmedBad)

        _ = health.recordSample(monotonicNow: 3, offset: 7, uncertainty: 2, nextInterval: 1_800)
        XCTAssertEqual(health.assessment, .inconclusive(offset: 7, uncertainty: 2))
        XCTAssertFalse(health.permitsRetirement)
        XCTAssertEqual(health.lastConfirmedBadSample, confirmedBad)

        _ = health.recordSample(monotonicNow: 4, offset: 0.25, uncertainty: 0.1, nextInterval: 1_800)
        XCTAssertEqual(health.lastAttempt, .sampled)
        XCTAssertEqual(health.assessment, .withinTolerance(offset: 0.25, uncertainty: 0.1))
        XCTAssertTrue(health.permitsRetirement)
        XCTAssertNil(health.lastConfirmedBadSample)
    }

    func testUnavailableFromNoSampleIsUnknownAndPermitted() throws {
        var health = try PeerClockHealth()
        _ = health.recordUnavailable(monotonicNow: 0, nextInterval: 1_800)
        XCTAssertEqual(health.assessment, .unknown)
        XCTAssertEqual(health.lastAttempt, .unavailable)
        XCTAssertTrue(health.permitsRetirement)
    }

    func testRejectsBadConfigurationIntervalsSamplesAndDeadlineOverflow() throws {
        XCTAssertThrowsError(try PeerClockHealth(configuration: .init(minimumInterval: 3)))
        XCTAssertThrowsError(try PeerClockHealth(configuration: .init(maximumInterval: .infinity)))
        XCTAssertThrowsError(try PeerClockHealth(configuration: .init(referenceHost: "  \n")))

        var health = try PeerClockHealth()
        XCTAssertEqual(health.schedule(monotonicNow: .nan, isIdle: true, interval: 1_800), .invalidInput)
        XCTAssertEqual(health.schedule(monotonicNow: 0, isIdle: true, interval: 3), .invalidInput)
        XCTAssertEqual(health.schedule(monotonicNow: 0, isIdle: true, interval: .infinity), .invalidInput)
        XCTAssertEqual(
            health.recordSample(monotonicNow: 0, offset: .nan, uncertainty: 0, nextInterval: 1_800),
            .invalidInput
        )
        XCTAssertEqual(
            health.recordSample(monotonicNow: 0, offset: 0, uncertainty: -1, nextInterval: 1_800),
            .invalidInput
        )
        XCTAssertEqual(
            health.recordUnavailable(monotonicNow: .greatestFiniteMagnitude, nextInterval: 1_800),
            .invalidInput
        )
        _ = health.recordUnavailable(monotonicNow: 5, nextInterval: 1_800)
        XCTAssertEqual(health.recordUnavailable(monotonicNow: 4, nextInterval: 1_800), .invalidInput)
        XCTAssertEqual(health.assessment, .unknown)
        XCTAssertEqual(health.lastAttempt, .unavailable)
    }
}
