import Foundation
import Testing

@testable import TractandaClient

private func freshFormatterReference(_ string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: string) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string)
}

@Test func timestampParsingMatchesFreshFormatterFallbackOrder() {
    let inputs = [
        "2026-09-27T12:34:56.789Z",
        "2026-09-27T12:34:56Z",
        "2026-09-27T12:34:56.125+02:30",
        "2026-09-27T12:34:56-07:00",
        "2026-09-27T12:34:56.123456789Z",
        "2026-09-27",
        "2026-09-27T12:34:56",
        "not-a-timestamp",
        "2026-13-27T12:34:56Z",
        "2026-09-27T12:34:56.789z",
    ]
    for input in inputs {
        #expect(Timestamp.parse(input) == freshFormatterReference(input))
    }
}

@Test func timestampParsingIsSafeAcrossConcurrentCallers() async {
    let values = [
        ("2026-09-27T12:34:56.789Z", true),
        ("2026-09-27T12:34:56Z", true),
        ("2026-09-27T12:34:56.125+02:30", true),
        ("2026-09-27T12:34:56", false),
        ("broken", false),
    ]
    await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<16 {
            group.addTask {
                for _ in 0..<250 {
                    for (input, shouldParse) in values {
                        if (Timestamp.parse(input) != nil) != shouldParse { return false }
                    }
                }
                return true
            }
        }
        for await succeeded in group { #expect(succeeded) }
    }
}

@Test func timestampParserReleaseBenchmarkWhenRequested() {
    guard ProcessInfo.processInfo.environment["TRACTANDA_TIMESTAMP_BENCHMARK"] == "1" else { return }
    let inputs = [
        "2026-09-27T12:34:56.789Z",
        "2026-09-27T12:34:56Z",
        "2026-09-27T12:34:56.125+02:30",
        "2026-09-27T12:34:56-07:00",
    ]
    let iterations = 20_000
    var referenceCount = 0
    let referenceStart = ContinuousClock.now
    for index in 0..<iterations where freshFormatterReference(inputs[index % inputs.count]) != nil {
        referenceCount += 1
    }
    let referenceElapsed = referenceStart.duration(to: .now)

    var optimizedCount = 0
    let optimizedStart = ContinuousClock.now
    for index in 0..<iterations where Timestamp.parse(inputs[index % inputs.count]) != nil {
        optimizedCount += 1
    }
    let optimizedElapsed = optimizedStart.duration(to: .now)

    #expect(referenceCount == iterations)
    #expect(optimizedCount == iterations)
    print(
        "Timestamp benchmark iterations=\(iterations) reference=\(referenceElapsed) "
            + "optimized=\(optimizedElapsed)"
    )
}
