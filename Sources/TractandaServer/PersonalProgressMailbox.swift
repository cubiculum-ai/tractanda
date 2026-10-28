import Synchronization
import TractandaCore

/// At most one drainer task and one latest value per active pull. Publishing never waits for
/// the runtime actor, throws into the driver, or creates an unbounded task/event queue.
final class PersonalProgressMailbox: Sendable {
    private struct State { var latest: PersonalPullProgress?; var draining = false }
    private let state = Mutex(State())
    private let deliver: @Sendable (PersonalPullProgress) async -> Void
    init(deliver: @escaping @Sendable (PersonalPullProgress) async -> Void) { self.deliver = deliver }
    func publish(_ value: PersonalPullProgress) {
        let start = state.withLock { state in
            state.latest = value
            if state.draining { return false }
            state.draining = true
            return true
        }
        if start { Task { await drain() } }
    }
    private func drain() async {
        while let value = state.withLock({ state -> PersonalPullProgress? in
            guard let next = state.latest else { state.draining = false; return nil }
            state.latest = nil
            return next
        }) { await deliver(value) }
    }
}
