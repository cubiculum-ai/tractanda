import Foundation
import Synchronization
import TractandaCore

/// One blocking socket operation at a time. Refreshes coalesce to the newest generation;
/// closing discards queued work. A late in-flight result is never delivered.
struct ServerStatusLoader: Sendable {
    private struct State: Sendable {
        var generation = 0
        var active = false
        var pending = false
        var delivery: (Int, String)?
    }
    private final class Mailbox: Sendable {
        let state = Mutex(State())
        let load: @Sendable (@escaping @Sendable () -> Bool) -> String
        init(load: @escaping @Sendable (@escaping @Sendable () -> Bool) -> String) { self.load = load }

        func schedule(_ generation: Int) {
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let text = load { [self] in state.withLock { $0.generation == generation } }
                let next: Int? = state.withLock {
                    if $0.generation == generation { $0.delivery = (generation, text) }
                    if $0.pending {
                        $0.pending = false
                        return $0.generation
                    }
                    $0.active = false
                    return nil
                }
                if let next { schedule(next) }
            }
        }
        func start() -> Int {
            let (generation, launch): (Int, Bool) = state.withLock {
                $0.generation += 1
                $0.delivery = nil
                if $0.active {
                    $0.pending = true
                    return ($0.generation, false)
                }
                $0.active = true
                return ($0.generation, true)
            }
            if launch { schedule(generation) }
            return generation
        }
        func cancel() {
            state.withLock {
                $0.generation += 1
                $0.pending = false
                $0.delivery = nil
            }
        }
    }
    private let mailbox: Mailbox
    init(load: @escaping @Sendable () -> String) { mailbox = Mailbox(load: { _ in load() }) }
    init(connection: ServerConnection) {
        mailbox = Mailbox { isCurrent in
            let client = ItemClient(transport: { request in
                try LocalTransport.call(
                    socket: connection.socketPath, request: request, serverUser: connection.serverUser)
            })
            return ServerStatusPresentation.text(client: client, shouldContinue: isCurrent)
        }
    }
    func cancel() { mailbox.cancel() }
    func hasDelivery() -> Bool { mailbox.state.withLock { $0.delivery != nil } }
    func take() -> (Int, String)? {
        mailbox.state.withLock { state in
            defer { state.delivery = nil }
            return state.delivery
        }
    }
    func start() -> Int { mailbox.start() }
}
