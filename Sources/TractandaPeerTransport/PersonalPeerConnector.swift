import Foundation
import NIOCore
import NIOPosix
import Synchronization
import TractandaCore

/// Owns only a single attempt's channel/cancellation state, never the event-loop group.
private final class PersonalPeerConnectState: Sendable {
    private struct State: Sendable {
        var channel: (any Channel)?
        var connection: PersonalPeerConnection?
        var failure: TractandaError?
    }
    private let state = Mutex(State())
    func attach(_ channel: any Channel) -> Bool {
        state.withLock { state in
            guard state.failure == nil, state.channel == nil else { return false }
            state.channel = channel
            return true
        }
    }
    func installed(_ connection: PersonalPeerConnection) {
        state.withLock { $0.connection = connection }
    }
    func connection(for channel: any Channel) throws -> PersonalPeerConnection {
        try state.withLock {
            if let failure = $0.failure { throw failure }
            guard $0.channel === channel, let connection = $0.connection else {
                throw TractandaError("connectionFailed", "Peer channel was not initialized.")
            }
            return connection
        }
    }
    func cancel(code: String = "cancelled") {
        let channel = state.withLock { state in
            if state.failure == nil { state.failure = TractandaError(code, "Peer connection attempt ended.") }
            return state.channel
        }
        channel?.close(promise: nil)
    }
    func close() async {
        cancel()
        let channel = state.withLock { $0.channel }
        if let channel { _ = try? await channel.closeFuture.get() }
    }
    func error(_ fallback: any Error) -> any Error { state.withLock { $0.failure ?? fallback } }
}

/// Owns the current single address attempt. Cancellation also fences late initializers.
private final class PersonalPeerConnectOwner: Sendable {
    private struct State: Sendable {
        var cancelled = false
        var attempt: PersonalPeerConnectState?
    }
    private let state = Mutex(State())
    func begin(_ attempt: PersonalPeerConnectState) -> Bool {
        state.withLock {
            guard !$0.cancelled else { return false }
            $0.attempt = attempt
            return true
        }
    }
    func cancel() {
        let attempt = state.withLock {
            $0.cancelled = true
            return $0.attempt
        }
        attempt?.cancel()
    }
}

/// A single hostname lookup and bounded address attempts. The mesh owner schedules reconnects.
/// Directional TLS roles concern this socket only; each member has a dialing context.
package enum PersonalPeerConnector {
    /// Starts alternatives in preference order without expiring a slower healthy handshake.
    /// Responder readiness reserves exactly one same-pair channel before acknowledging it.
    package static func connect(
        group: MultiThreadedEventLoopGroup, endpoints: [PeerRuntimeConfiguration.Endpoint],
        pairing: PeerPairing, operations: PersonalPeerOperations, resolver: PeerNameResolver,
        limits: PersonalPeerLimits = .init(), connectSeconds: Double = 30,
        staggerSeconds: Double = 0.25
    ) async throws -> PersonalPeerConnection {
        guard (1...PeerRuntimeConfiguration.Peer.maximumEndpoints).contains(endpoints.count),
            staggerSeconds.isFinite, staggerSeconds >= 0, staggerSeconds <= 5
        else { throw TractandaError("invalidConfiguration", "Invalid ordered peer destinations.") }
        return try await withThrowingTaskGroup(of: Result<PersonalPeerConnection, Error>.self) { tasks in
            for (index, endpoint) in endpoints.enumerated() {
                tasks.addTask {
                    do {
                        if index > 0 {
                            try await Task.sleep(for: .seconds(Double(index) * staggerSeconds))
                        }
                        try Task.checkCancellation()
                        return .success(
                            try await connect(
                                group: group, host: endpoint.host, port: endpoint.port, pairing: pairing,
                                operations: operations, resolver: resolver, limits: limits,
                                connectSeconds: connectSeconds))
                    } catch { return .failure(error) }
                }
            }
            var winner: PersonalPeerConnection?
            var failure: any Error = TractandaError("connectionFailed", "No peer destination connected.")
            for try await result in tasks {
                switch result {
                case .success(let connection):
                    if winner == nil, !Task.isCancelled {
                        winner = connection
                        tasks.cancelAll()
                    } else {
                        try? await connection.close().get()
                    }
                case .failure(let error): failure = error
                }
            }
            if Task.isCancelled {
                if let winner { try? await winner.close().get() }
                throw CancellationError()
            }
            guard let winner else { throw failure }
            return winner
        }
    }
    package static func connect(
        group: MultiThreadedEventLoopGroup, host: String, port: Int, pairing: PeerPairing,
        operations: PersonalPeerOperations, resolver: PeerNameResolver,
        limits: PersonalPeerLimits = .init(), connectSeconds: Double = 30
    ) async throws -> PersonalPeerConnection {
        try limits.validate()
        guard connectSeconds.isFinite, connectSeconds > 0, connectSeconds <= 300,
            (1...65_535).contains(port)
        else {
            throw TractandaError("invalidConfiguration", "Invalid peer port.")
        }
        guard pairing.tls.role == .initiator else {
            throw TractandaError("invalidPeerRole", "Only the configured initiator can connect.")
        }
        let owner = PersonalPeerConnectOwner()
        let end =
            NIODeadline.now()
            + .nanoseconds(Int64((connectSeconds + limits.handshakeSeconds) * 1_000_000_000))
        func remaining() throws -> Int64 {
            let now = NIODeadline.now()
            guard now < end else {
                throw TractandaError("deadlineExceeded", "Peer connection deadline expired.")
            }
            return Int64((end - now).nanoseconds)
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let addresses = try await resolver.resolve(host: host, port: port, seconds: connectSeconds)
            try Task.checkCancellation()
            var failure: any Error = TractandaError("connectionFailed", "No peer address connected.")
            for (index, address) in addresses.enumerated() {
                try Task.checkCancellation()
                let budget = try remaining()
                let state = PersonalPeerConnectState()
                guard owner.begin(state) else { throw CancellationError() }
                do {
                    // A dead first address cannot consume every remaining address's opportunity.
                    let share = max(
                        1,
                        min(
                            Int64(connectSeconds * 1_000_000_000),
                            budget / Int64(addresses.count - index)))
                    let channel = try await ClientBootstrap(group: group)
                        .connectTimeout(.nanoseconds(share))
                        .channelInitializer { channel in
                            guard state.attach(channel) else {
                                channel.close(promise: nil)
                                return channel.eventLoop.makeFailedFuture(
                                    TractandaError("cancelled", "Peer connection cancelled."))
                            }
                            return PersonalPeerConnection.install(
                                on: channel, pairing: pairing,
                                operations: operations, limits: limits
                            ).map { state.installed($0) }
                        }.connect(to: address).get()
                    let handshake = min(try remaining(), Int64(limits.handshakeSeconds * 1_000_000_000))
                    let deadline = channel.eventLoop.scheduleTask(in: .nanoseconds(handshake)) {
                        state.cancel(code: "deadlineExceeded")
                    }
                    defer { deadline.cancel() }
                    let connection = try state.connection(for: channel)
                    _ = try await connection.ready.get()
                    try Task.checkCancellation()
                    _ = try remaining()
                    _ = try state.connection(for: channel)
                    return connection
                } catch {
                    failure = state.error(error)
                    // No next candidate begins before this one's close has actually completed.
                    await state.close()
                    try Task.checkCancellation()
                }
            }
            throw failure
        } onCancel: {
            owner.cancel()
        }
    }
}
