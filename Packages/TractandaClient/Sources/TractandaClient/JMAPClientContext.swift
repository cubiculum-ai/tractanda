import Foundation

public enum JMAPArgumentEncoding: Sendable { case canonical, wire }

/// A connection owns discovery for exactly one transport and authentication context.
/// Metadata changes invalidate the next request; completed calls are never replayed.
public actor JMAPClientContext {
    private let transport: any ItemTransport
    private var cache = JMAPDiscoveryCache()
    private var context: String?
    private var generation = 0
    private var discovery: (generation: Int, task: Task<JMAPDiscoverySession, Error>)?

    public init(transport: any ItemTransport) { self.transport = transport }

    public func invalidate() {
        generation += 1
        cache = JMAPDiscoveryCache()
        discovery = nil
        context = nil
    }

    public func send(
        method: String, arguments: JMAPValue, callID: String = "client",
        argumentEncoding: JMAPArgumentEncoding = .canonical
    ) async throws -> Data {
        let selected = try await transport.discoveryContext()
        if context != selected {
            invalidate()
            context = selected
        }
        let selectedGeneration = generation
        let accountID: String?
        if TractandaJMAP.scope(of: method) == .account {
            accountID = try await session().accountID
        } else {
            accountID = nil
        }
        // A concurrent authentication change must not send a request prepared for the old identity.
        guard context == selected, generation == selectedGeneration,
            try await transport.discoveryContext() == selected
        else {
            throw TractandaError("contextChanged", "Authentication context changed; prepare a new request.")
        }
        let prepared = try TractandaJMAP.prepareArguments(
            method: method, arguments: arguments, accountID: accountID)
        let wire =
            argumentEncoding == .canonical
            ? try TractandaJMAPCodec.argumentsToWire(method: method, arguments: prepared) : prepared
        let request = try Self.envelope(method: method, arguments: wire, callID: callID)
        guard request.count <= ItemClient.maximumMessageBytes else {
            throw TractandaError("requestLimit", "Request exceeds the native message limit.")
        }
        let response = try await transport.send(request)
        guard response.count <= ItemClient.maximumMessageBytes else {
            throw TractandaError("responseLimit", "Response exceeds the native message limit.")
        }
        if context == selected, generation == selectedGeneration,
            let state = try? JMAPValue.decode(response)["sessionState"]?.text
        {
            cache.observe(sessionState: state)
        }
        try JMAPReadResponseValidator.validate(
            response, calls: JMAPRequest.decode(request).methodCalls, discoveredAccountID: accountID)
        return response
    }

    private func session() async throws -> JMAPDiscoverySession {
        if let session = cache.session { return session }
        let current = generation
        let task: Task<JMAPDiscoverySession, Error>
        if let pending = discovery, pending.generation == current {
            task = pending.task
        } else {
            let transport = transport
            task = Task {
                let request = try Self.envelope(
                    method: TractandaJMAP.discoveryMethod, arguments: .object([]), callID: "discovery")
                let data = try await transport.send(request)
                guard data.count <= ItemClient.maximumMessageBytes else {
                    throw TractandaError(
                        "responseLimit", "Discovery response exceeds the native message limit.")
                }
                let value = try JMAPValue.decode(data)
                if let problem = value["type"]?.text, problem.hasPrefix("urn:ietf:params:jmap:error:") {
                    throw TractandaError(
                        String(problem.dropFirst("urn:ietf:params:jmap:error:".count)),
                        "Local discovery was rejected.")
                }
                guard let calls = value["methodResponses"]?.elements, calls.count == 1,
                    let call = calls[0].elements, call.count == 3, call[2].text == "discovery"
                else { throw TractandaError("protocolError", "Invalid local discovery response.") }
                if call[0].text == "error", let type = call[1]["type"]?.text {
                    throw TractandaError(type, call[1]["description"]?.text ?? "")
                }
                guard call[0].text == TractandaJMAP.discoveryMethod else {
                    throw TractandaError("protocolError", "Invalid local discovery response.")
                }
                return try JMAPDiscoverySession(data: call[1].encoded())
            }
            discovery = (current, task)
        }
        do {
            let session = try await task.value
            guard generation == current else {
                throw TractandaError("contextChanged", "Authentication context changed during discovery.")
            }
            cache.accept(session)
            discovery = nil
            return session
        } catch {
            if generation == current { discovery = nil }
            throw error
        }
    }

    private static func envelope(method: String, arguments: JMAPValue, callID: String) throws -> Data {
        try JMAPValue.object([
            JMAPMember("using", .array(TractandaJMAP.using.map(JMAPValue.string))),
            JMAPMember("methodCalls", .array([.array([.string(method), arguments, .string(callID)])])),
        ]).encoded()
    }
}
