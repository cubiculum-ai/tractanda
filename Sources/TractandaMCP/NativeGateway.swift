import Foundation
import MCP
import TractandaCore

/// Serializes native calls off the cooperative executor; bounds outstanding work per adapter.
actor NativeGateway {
    static let maximumArgumentSize = 1024 * 1024
    static let maximumResultSize = 512 * 1024
    private let connection: ServerConnection?
    private let backend: (@Sendable (Data) async throws -> Data)?
    private let queue = DispatchQueue(label: "ai.tractanda.mcp.native")
    private var pendingCalls = 0

    init(connection: ServerConnection) {
        self.connection = connection
        backend = nil
    }
    init(socketPath: String) {
        self.connection = ServerConnection(socketPath: socketPath)
        backend = nil
    }
    init(backend: @escaping @Sendable (Data) async throws -> Data) {
        connection = nil
        self.backend = backend
    }

    func call(_ method: String, arguments: [String: Value]) async throws -> Data {
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(arguments)
        guard data.count <= Self.maximumArgumentSize else {
            throw TractandaError(
                "requestTooLarge", "MCP arguments exceed 1 MiB; use the native client for larger content.")
        }
        guard pendingCalls < 32 else {
            throw TractandaError("busy", "Too many pending native calls; retry later.")
        }
        pendingCalls += 1
        defer { pendingCalls -= 1 }
        let result: Data
        if let backend {
            let arguments = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let envelope = try JSONSerialization.data(
                withJSONObject: [
                    "using": [ItemService.capability], "methodCalls": [[method, arguments, "client"]],
                ], options: [.sortedKeys])
            result = try Self.unwrap(try await backend(envelope), method: method)
        } else if let connection {
            result = try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        let arguments = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                        continuation.resume(
                            returning: try ItemClient(connection: connection).call(
                                method, arguments: arguments))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } else {
            throw TractandaError("connectionClosed", "Native gateway is unavailable.")
        }
        let compactWriteMethods = [
            "TractandaItem/commit", "TractandaLearning/feedback", "TractandaLearning/settings",
        ]
        let adapted =
            compactWriteMethods.contains(method)
            ? try compactWriteResult(result)
            : result
        guard adapted.count <= Self.maximumResultSize else {
            throw TractandaError(
                "responseTooLarge",
                "Result exceeds 512 KiB. Request fewer items/a smaller page, or use the native client. A write may already have committed; retain its operationID."
            )
        }
        return adapted
    }

    private static func unwrap(_ response: Data, method: String) throws -> Data {
        guard let decoded = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw TractandaError("protocolError", "Invalid native response.")
        }
        if let code = decoded["code"] as? String {
            throw TractandaError(code, decoded["message"] as? String ?? "")
        }
        guard let calls = decoded["methodResponses"] as? [[Any]], calls.count == 1,
            calls[0].count == 3, calls[0][2] as? String == "client",
            let result = calls[0][1] as? [String: Any]
        else { throw TractandaError("protocolError", "Missing native method response.") }
        if calls[0][0] as? String == "error" {
            throw TractandaError(result["type"] as? String ?? "error", result["description"] as? String ?? "")
        }
        guard calls[0][0] as? String == method else {
            throw TractandaError("protocolError", "Unexpected method result.")
        }
        return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    }

    /// MCP's ordinary write reply follows content projection and omits only the server-owned
    /// request identity. This intentionally touches only revision.fields.requestIdentity,
    /// never user keys at another path, and never the canonical record returned by the native
    /// service. Explicit retrieval with projection=full remains byte-for-field native output.
    private func compactWriteResult(_ data: Data) throws -> Data {
        guard case .object(var result) = try JSONDecoder().decode(Value.self, from: data),
            case .object(var revision)? = result["revision"],
            case .object(var fields)? = revision["fields"]
        else { return data }
        guard fields.removeValue(forKey: "requestIdentity") != nil else { return data }
        revision["fields"] = .object(fields)
        result["revision"] = .object(revision)
        return try JSONEncoder().encode(Value.object(result))
    }
}
