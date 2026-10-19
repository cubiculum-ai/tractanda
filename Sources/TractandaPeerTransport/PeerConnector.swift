import Foundation
import NIOCore
import NIOPosix
import Synchronization
import TractandaCore

package struct PeerConnectionLimits: Sendable {
    package var connectSeconds: Double = 5
    package var handshakeSeconds: Double = 10
    package var exchange = PeerExchangeLimits()
    package init() {}
    package func validate() throws {
        guard connectSeconds.isFinite, connectSeconds > 0, connectSeconds <= 30,
            handshakeSeconds.isFinite, handshakeSeconds > 0, handshakeSeconds <= 30
        else {
            throw TractandaError("resourceLimit", "Invalid peer connection deadlines.")
        }
        try exchange.validate()
    }
}

/// Owns only a single attempt's channel/cancellation state, never the event-loop group.
private final class PeerConnectState: Sendable {
    private struct State: Sendable {
        var channel: (any Channel)?
        var connection: PeerExchangeConnection?
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
    func installed(_ connection: PeerExchangeConnection) {
        state.withLock { $0.connection = connection }
    }
    func connection(for channel: any Channel) throws -> PeerExchangeConnection {
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
private final class PeerConnectOwner: Sendable {
    private struct State: Sendable {
        var cancelled = false
        var attempt: PeerConnectState?
    }
    private let state = Mutex(State())
    func begin(_ attempt: PeerConnectState) -> Bool {
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

/// Fixed-role, one bounded lookup followed by sequential address attempts. No retries are scheduled.
package enum PeerConnector {
    package static func connect(
        group: MultiThreadedEventLoopGroup, host: String, port: Int, pairing: PeerPairing,
        coordinator: ServiceCoordinator, resolver: PeerNameResolver, limits: PeerConnectionLimits = .init(),
        authorizeAdmission: @escaping @Sendable () async throws -> Void = {},
        logicalLease: PeerLogicalLeaseFactory? = nil
    ) async throws -> PeerExchangeConnection {
        try limits.validate()
        guard (1...65_535).contains(port) else {
            throw TractandaError("invalidConfiguration", "Invalid peer port.")
        }
        guard pairing.tls.role == .initiator else {
            throw TractandaError("invalidPeerRole", "Only the configured initiator can connect.")
        }
        let owner = PeerConnectOwner()
        let end =
            NIODeadline.now()
            + .nanoseconds(Int64((limits.connectSeconds + limits.handshakeSeconds) * 1_000_000_000))
        func remaining() throws -> Int64 {
            let now = NIODeadline.now()
            guard now < end else {
                throw TractandaError("deadlineExceeded", "Peer connection deadline expired.")
            }
            return Int64((end - now).nanoseconds)
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let addresses = try await resolver.resolve(host: host, port: port, seconds: limits.connectSeconds)
            try Task.checkCancellation()
            var failure: any Error = TractandaError("connectionFailed", "No peer address connected.")
            for (index, address) in addresses.enumerated() {
                try Task.checkCancellation()
                let budget = try remaining()
                let state = PeerConnectState()
                guard owner.begin(state) else { throw CancellationError() }
                do {
                    // A dead first address cannot consume every remaining address's opportunity.
                    let share = max(
                        1,
                        min(
                            Int64(limits.connectSeconds * 1_000_000_000),
                            budget / Int64(addresses.count - index)))
                    let channel = try await ClientBootstrap(group: group)
                        .connectTimeout(.nanoseconds(share))
                        .channelInitializer { channel in
                            guard state.attach(channel) else {
                                channel.close(promise: nil)
                                return channel.eventLoop.makeFailedFuture(
                                    TractandaError("cancelled", "Peer connection cancelled."))
                            }
                            return PeerExchangeConnection.install(
                                on: channel, pairing: pairing,
                                coordinator: coordinator, limits: limits.exchange,
                                authorizeAdmission: authorizeAdmission, logicalLease: logicalLease
                            ).map { state.installed($0) }
                        }.connect(to: address).get()
                    let handshake = min(try remaining(), Int64(limits.handshakeSeconds * 1_000_000_000))
                    let deadline = channel.eventLoop.scheduleTask(in: .nanoseconds(handshake)) {
                        state.cancel(code: "deadlineExceeded")
                    }
                    defer { deadline.cancel() }
                    let connection = try state.connection(for: channel)
                    try await connection.ready.get()
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
