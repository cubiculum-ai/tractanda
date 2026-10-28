import Foundation
import TractandaClient

/// Synchronous discovery and response observation for one endpoint and authenticated OS identity.
/// The retained discovery transport is also used by checked forwarding adapters.
public final class NativeClientContext {
    private let lock = NSRecursiveLock()
    private let discover: (Data) throws -> Data
    private var cache = JMAPDiscoveryCache()

    public init(transport: @escaping (Data) throws -> Data) { discover = transport }

    public func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        cache = JMAPDiscoveryCache()
    }

    public func send(
        _ envelope: Data, argumentEncoding: JMAPArgumentEncoding = .canonical,
        transport: (Data) throws -> Data
    ) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        let request = try JMAPRequest.decode(envelope)
        let needsAccount = request.methodCalls.contains { TractandaJMAP.scope(of: $0.name) == .account }
        if needsAccount && cache.session == nil {
            let discovery = try Self.envelope(calls: [
                [TractandaJMAP.discoveryMethod, [:] as [String: Any], "discovery"]
            ])
            let response = try discover(discovery)
            let payload = try NativeMethodResult.unwrap(
                response, method: TractandaJMAP.discoveryMethod, callID: "discovery")
            cache.accept(try JMAPDiscoverySession(data: payload))
        }
        let selectedAccountID = cache.session?.accountID
        let calls = try request.methodCalls.map { call in
            JMAPValue.array([
                .string(call.name),
                try Self.wireArguments(call, accountID: cache.session?.accountID, encoding: argumentEncoding),
                .string(call.callID),
            ])
        }
        // Preserve all request envelope members, including createdIds and exact argument references.
        let original = try JMAPValue.decode(envelope)
        let prepared = JMAPValue.object(
            (original.members ?? []).map { member in
                member.name == "methodCalls" ? JMAPMember(member.name, .array(calls)) : member
            })
        let bytes = try prepared.encoded()
        let response = try transport(bytes)
        if let state = try? JMAPValue.decode(response)["sessionState"]?.text {
            cache.observe(sessionState: state)
        }
        try JMAPReadResponseValidator.validate(
            response, calls: JMAPRequest.decode(bytes).methodCalls, discoveredAccountID: selectedAccountID)
        return response
    }

    private static func wireArguments(
        _ call: JMAPInvocation, accountID: String?, encoding: JMAPArgumentEncoding
    ) throws -> JMAPValue {
        let prepared = try TractandaJMAP.prepareArguments(
            method: call.name, arguments: call.arguments, accountID: accountID)
        return encoding == .canonical
            ? try TractandaJMAPCodec.argumentsToWire(method: call.name, arguments: prepared) : prepared
    }

    public static func envelope(calls: [[Any]]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "using": TractandaJMAP.using, "methodCalls": calls,
            ], options: [.sortedKeys])
    }
}

/// Async adapters retain one SDK context without exposing JSON implementation types to callers.
public struct NativeAsyncClientContext: Sendable {
    private struct Transport: ItemTransport {
        let sender: @Sendable (Data) async throws -> Data
        func send(_ request: Data) async throws -> Data { try await sender(request) }
    }
    private let context: JMAPClientContext
    public init(transport: @escaping @Sendable (Data) async throws -> Data) {
        context = JMAPClientContext(transport: Transport(sender: transport))
    }
    public func send(
        method: String, arguments: Data, callID: String = "client", argumentsAreWire: Bool = false
    ) async throws -> Data {
        try await context.send(
            method: method, arguments: JMAPValue.decode(arguments), callID: callID,
            argumentEncoding: argumentsAreWire ? .wire : .canonical)
    }
    public func invalidate() async { await context.invalidate() }
}
