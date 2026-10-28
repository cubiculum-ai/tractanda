import Foundation
import TractandaCore

/// Native Unix-socket administration only. HTTP/MCP dispatch never installs this route.
struct PersonalPeerAdminCall {
    static let method = "TractandaPeerPersonal/admin"
    let callID: String
    let request: PeerExchangeRequest
    static func parse(_ call: NativeMethodInvocation) throws -> Self? {
        guard call.method == method else { return nil }
        let arguments = try call.dictionary()
        guard call.callCount == 1, try call.argumentsJSON.count <= 256 * 1024 else {
            throw TractandaError(
                "invalidArguments", "Use one bounded native personal peer administration invocation.")
        }
        let id = call.callID
        let input = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        // Native envelopes permit ordinary JSON whitespace/escaping. Canonical peer-wire
        // byte equality applies to TLS frames, not to this already parsed local envelope.
        let request = try JSON.decode(PeerExchangeRequest.self, input)
        guard Set(arguments.keys) == ["operation", "fields"], request.operation.utf8.count <= 128 else {
            throw TractandaError("invalidArguments", "Unknown personal administration fields.")
        }
        return Self(callID: id, request: request)
    }
    func response(_ bytes: Data) throws -> NativeMethodOutcome {
        guard bytes.count <= 256 * 1024 else {
            throw TractandaError("resourceLimit", "Personal administration response exceeds its bound.")
        }
        let object = try JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed])
        return try .nativeSuccess(Self.method, object)
    }
}
