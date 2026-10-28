import Crypto
import Foundation
import TractandaClient

public typealias JMAPVisibleStates = [String: [String: String]]
public typealias JMAPStateProvider = @Sendable (JMAPHTTPAuthentication) async throws -> JMAPVisibleStates

/// Coalesces at the consumer boundary: a slow reader owns one state snapshot, never a change queue.
public actor JMAPEventHub: JMAPNotificationHTTPProvider {
    public nonisolated let maximumObjectsInSet: Int64 = Int64(TractandaJMAP.maximumObjectsInSet)
    private let stateProvider: JMAPStateProvider
    private let pushes: JMAPPushSubscriptions
    private let now: @Sendable () -> Date
    private var streams: [String: JMAPStateStream] = [:]
    private var streamCredentials: [String: String] = [:]
    private var closed = false
    private var monitor: Task<Void, Never>?
    // Instance-local suspension seam for the shutdown/admission regression; never wire configured.
    private var afterStreamCleanupForTesting: (@Sendable () async -> Void)?

    public init(
        stateProvider: @escaping JMAPStateProvider,
        callbackTransport: any JMAPCallbackTransport,
        credentialResolver: @escaping @Sendable (String) async throws -> JMAPHTTPAuthentication?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        self.stateProvider = stateProvider
        self.now = now
        pushes = try JMAPPushSubscriptions(
            stateProvider: stateProvider, transport: callbackTransport,
            credentialResolver: credentialResolver, now: now)
    }

    public func subscribe(
        types: [String]?, closeAfterState: Bool, pingSeconds: Int, lastEventID: String?,
        authentication: JMAPHTTPAuthentication
    ) async throws -> any JMAPSSESubscription {
        try await authentication.revalidate()
        guard !closed, authentication.expiresAt > now(), pingSeconds >= 0,
            lastEventID?.utf8.count ?? 0 <= 1024
        else { throw TractandaError("invalidArguments", "Invalid event subscription.") }
        let selected = try JMAPEventState.types(types)
        // Retire streams whose credential expired even when their reader stopped asking for events.
        for (id, stream) in streams where await stream.isExpired(at: now()) {
            await stream.cancel()
            streams.removeValue(forKey: id)
            streamCredentials.removeValue(forKey: id)
        }
        if let barrier = afterStreamCleanupForTesting { await barrier() }
        // Cleanup yields to other actors. close() may have drained all streams during that yield;
        // admission and registration below must form one non-suspending actor turn after this check.
        guard !closed else { throw TractandaError("serviceClosed", "Notifications are closed.") }
        guard streams.count < 128,
            streamCredentials.values.filter({ $0 == authentication.credentialID }).count < 4
        else { throw TractandaError("resourceLimit", "Event subscription capacity is full.") }
        let id = try UUID.makeVersion1().uuidString.lowercased()
        let stream = JMAPStateStream(
            authentication: authentication, types: selected, closeAfterState: closeAfterState,
            pingSeconds: pingSeconds == 0 ? 0 : max(1, min(300, pingSeconds)),
            lastEventID: lastEventID, stateProvider: stateProvider, now: now,
            release: { [weak self] in await self?.removeStream(id) })
        if monitor == nil {
            monitor = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { break }
                    guard let self else { break }
                    await self.reapStreams()
                }
            }
        }
        streams[id] = stream
        streamCredentials[id] = authentication.credentialID
        return stream
    }

    public func methods(authentication: JMAPHTTPAuthentication) async throws -> [String: JMAPMethodDefinition]
    {
        guard !closed else { throw TractandaError("serviceClosed", "Notifications are closed.") }
        try await authentication.revalidate()
        return await pushes.methods(authentication: authentication)
    }
    public func close() async {
        closed = true
        monitor?.cancel()
        monitor = nil
        let active = Array(streams.values)
        streams.removeAll()
        streamCredentials.removeAll()
        for stream in active { await stream.cancel() }
        await pushes.close()
    }
    package func setStreamAdmissionBarrierForTesting(_ barrier: @escaping @Sendable () async -> Void) {
        afterStreamCleanupForTesting = barrier
    }
    private func reapStreams() async {
        for stream in Array(streams.values) where !(await stream.credentialIsCurrent()) {
            await stream.cancel()
        }
    }
    private func removeStream(_ id: String) {
        streams.removeValue(forKey: id)
        streamCredentials.removeValue(forKey: id)
    }
}

package enum JMAPEventState {
    package static let supported: Set<String> = ["TractandaItem", "TractandaRevision"]
    package static func types(_ values: [String]?) throws -> Set<String>? {
        guard let values else { return nil }
        guard values.count <= 64, Set(values).count == values.count,
            values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 })
        else { throw TractandaError("invalidArguments", "Invalid notification types.") }
        // An unknown type has no changes; subscriptions may outlive a capability being installed.
        return Set(values)
    }
    package static func filtered(_ states: JMAPVisibleStates, types: Set<String>?) -> JMAPVisibleStates {
        states.compactMapValues { state in
            let selected = state.filter { supported.contains($0.key) && (types?.contains($0.key) ?? true) }
            return selected.isEmpty ? nil : selected
        }
    }
    package static func value(_ states: JMAPVisibleStates) -> JMAPValue {
        .object([
            .init("@type", .string("StateChange")),
            .init(
                "changed",
                .object(
                    states.keys.sorted().map { account in
                        .init(
                            account,
                            .object(
                                states[account]!.keys.sorted().map {
                                    .init($0, .string(states[account]![$0]!))
                                }))
                    })),
        ])
    }
    package static func id(_ states: JMAPVisibleStates) throws -> String {
        SHA256.hash(data: try value(states).encoded()).map { String(format: "%02x", $0) }.joined()
    }
}

private actor JMAPStateStream: JMAPSSESubscription {
    let authentication: JMAPHTTPAuthentication
    let types: Set<String>?
    let closeAfterState: Bool
    let pingSeconds: Int
    let stateProvider: JMAPStateProvider
    let now: @Sendable () -> Date
    let release: @Sendable () async -> Void
    var lastID: String?
    var lastEvent: Date
    var closed = false
    var reading = false
    var sleeper: Task<Void, Error>?

    init(
        authentication: JMAPHTTPAuthentication, types: Set<String>?, closeAfterState: Bool,
        pingSeconds: Int, lastEventID: String?, stateProvider: @escaping JMAPStateProvider,
        now: @escaping @Sendable () -> Date, release: @escaping @Sendable () async -> Void
    ) {
        self.authentication = authentication
        self.types = types
        self.closeAfterState = closeAfterState
        self.pingSeconds = pingSeconds
        self.stateProvider = stateProvider
        self.now = now
        self.release = release
        self.lastID = lastEventID
        self.lastEvent = now()
    }
    func isExpired(at instant: Date) -> Bool { closed || authentication.expiresAt <= instant }
    func credentialIsCurrent() async -> Bool {
        guard !closed, authentication.expiresAt > now() else { return false }
        return (try? await authentication.checkCurrent()) != nil
    }
    func next() async throws -> JMAPSSEEvent? {
        guard !closed else { return nil }
        guard !reading else { throw TractandaError("resourceLimit", "One event read is allowed at a time.") }
        reading = true
        defer { reading = false }
        do {
            while !closed {
                try Task.checkCancellation()
                guard authentication.expiresAt > now() else {
                    await cancel()
                    return nil
                }
                try await authentication.checkCurrent()
                let state = JMAPEventState.filtered(try await stateProvider(authentication), types: types)
                try await authentication.checkCurrent()
                guard !closed else { return nil }
                let id = try JMAPEventState.id(state)
                if id != lastID && !state.isEmpty {
                    lastID = id
                    lastEvent = now()
                    if closeAfterState { await cancel() }
                    return .init(name: "state", id: id, data: JMAPEventState.value(state))
                }
                if pingSeconds > 0, now().timeIntervalSince(lastEvent) >= Double(pingSeconds) {
                    lastEvent = now()
                    return .init(
                        name: "ping",
                        data: .object([
                            .init("interval", .number(try JMAPNumber(String(pingSeconds))))
                        ]))
                }
                let sleep = Task { try await Task.sleep(for: .seconds(1)) }
                sleeper = sleep
                try await withTaskCancellationHandler {
                    try await sleep.value
                } onCancel: {
                    sleep.cancel()
                }
                sleeper = nil
            }
            return nil
        } catch is CancellationError {
            await cancel()
            return nil
        } catch {
            await cancel()
            throw error
        }
    }
    func cancel() async {
        guard !closed else { return }
        closed = true
        sleeper?.cancel()
        sleeper = nil
        await release()
    }
}
