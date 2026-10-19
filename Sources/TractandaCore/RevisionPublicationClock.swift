import Foundation

/// Publication time is deliberately representable by existing millisecond indexes/filters.
/// UUIDv1 issuance still comes from the real generator and is independent of this logical clock.
enum RevisionPublicationClock {
    static func after(_ inputs: [String], now: () -> String) throws -> String {
        guard !inputs.isEmpty, inputs.count <= 4096 else {
            throw TractandaError("invalidMergeTimestamp", "Publication needs bounded causal clock inputs.")
        }
        let exact = try inputs.map(RevisionTimestamp.init)
        let maximum = exact.map(\.ticks).max()!
        let current = try RevisionTimestamp(now()).ticks
        let advanced = floorMillisecond(maximum).addingReportingOverflow(20_000)
        guard !advanced.overflow else {
            throw TractandaError("invalidMergeTimestamp", "Publication clock exhausted its range.")
        }
        let ticks = max(advanced.partialValue, floorMillisecond(current))
        let full = try RevisionTimestamp(ticks: ticks).formatted()
        let result = String(full.prefix(23)) + "Z"
        guard try RevisionTimestamp(result).ticks == ticks, ticks > maximum,
            let published = Timestamp.parse(result)
        else { throw TractandaError("invalidMergeTimestamp", "Publication clock cannot round-trip safely.") }
        for input in inputs {
            guard let parsed = Timestamp.parse(input), published > parsed else {
                throw TractandaError(
                    "invalidMergeTimestamp", "Publication must remain newer through the runtime date parser.")
            }
        }
        return result
    }

    private static func floorMillisecond(_ ticks: Int64) -> Int64 {
        let remainder = ticks % 10_000
        return ticks - remainder - (remainder < 0 ? 10_000 : 0)
    }
}
