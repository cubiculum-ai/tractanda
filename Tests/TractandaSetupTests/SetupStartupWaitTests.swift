import XCTest

@testable import TractandaSetup

final class SetupStartupWaitTests: XCTestCase {
    func testLiveStartupCanExceedTwoHoursWithoutAnOverallDeadline() throws {
        var clock = 0.0
        var attempts = 0
        var observations = 0
        var reports: [String] = []
        try SetupStartupWait.run(
            observe: {
                observations += 1
                if observations == 1 { throw SetupProcessTimeout(message: "Bounded observation timed out") }
                return .init(detail: "Owned PID still starting")
            },
            probe: {
                attempts += 1
                if clock <= 7200 { throw SetupError("Socket not published yet") }
            }, now: { clock }, sleep: { clock += 300 }, cancelled: { false },
            report: { reports.append($0) })
        XCTAssertGreaterThan(clock, 7200)
        XCTAssertEqual(attempts, 25)
        XCTAssertEqual(reports.count, 3, "Unchanged observations must not fabricate progress")
    }
    func testActualExitFailsWithoutRetryingReadiness() {
        var attempts = 0
        XCTAssertThrowsError(
            try SetupStartupWait.run(
                observe: { .init(detail: "Exited", failure: "Owned process exited with status 3") },
                probe: { attempts += 1 }, sleep: {}, cancelled: { false }, report: { _ in }))
        XCTAssertEqual(attempts, 0)
    }
    func testOperatorCancellationStopsWaitWithoutADeadline() {
        var cancelled = false
        var attempts = 0
        XCTAssertThrowsError(
            try SetupStartupWait.run(
                observe: { .init(detail: "Starting") },
                probe: {
                    attempts += 1
                    throw SetupError("Waiting")
                },
                sleep: { cancelled = true }, cancelled: { cancelled }, report: { _ in }))
        XCTAssertEqual(attempts, 1)
    }
    func testStartupChildIgnoresOrdinaryHelperDeadlineAndRetainsExitStatus() throws {
        let runner = FoundationProcessRunner(timeout: 0.01)
        let result = try runner.runStartup("/bin/sh", ["-c", "sleep 0.1; exit 7"], environment: [:])
        XCTAssertEqual(result.status, 7)
        XCTAssertThrowsError(try runner.run("/bin/sleep", ["1"], environment: [:]))
    }
    func testUnboundedStartupChildStillHonorsCancellationAndOutputCap() {
        XCTAssertThrowsError(
            try FoundationProcessRunner(timeout: nil, cancelled: { true }).run(
                "/bin/sleep", ["1"], environment: [:]))
        XCTAssertThrowsError(
            try FoundationProcessRunner(timeout: nil, maximumOutputBytes: 128).run(
                "/bin/sh", ["-c", "printf %0130d 0; sleep 0.1"], environment: [:]))
    }

}
